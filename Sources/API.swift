import Foundation

/// 后端错误协议（api.py 逐条对齐）：
///   400 = ValidationError / 硬拒（force 也不放行）→ `.rejected`
///   409 = 软警告，客户端确认后带 force=on 重试 → `.needsForce`
///   404 = 未过闸 或 记录不存在（后端刻意不区分）→ `.gone`
///   401 = /api/login 密码错
enum APIError: LocalizedError {
    case rejected(String)
    case needsForce([Warn])
    case gone
    case unauthorized(String)
    case transport(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let m): return m
        case .needsForce(let w): return w.map(\.message).joined(separator: "；")
        case .gone: return "登录已失效或记录不存在"
        case .unauthorized(let m): return m
        case .transport(let m): return "网络错误：\(m)"
        case .decode(let m): return "响应解析失败：\(m)"
        }
    }
}

/// 会话凭证。小程序那条路踩过的坑同样适用于 iOS：`/api/login` 返回的是 cookie **值**
/// （不是 Set-Cookie），必须自己存起来、每个请求手动拼 `Cookie: fc_coach=…`。
/// URLSession 的自动 cookie jar 在这里帮不上忙 —— 后端根本没发 Set-Cookie。
@MainActor
final class Session: ObservableObject {
    static let coachCookieName = "fc_coach"
    private static let kCoach = "fitcoach.coachCookie"
    private static let kStudent = "fitcoach.studentToken"
    private static let kBase = "fitcoach.baseURL"

    @Published var coachCookie: String? {
        didSet { UserDefaults.standard.set(coachCookie, forKey: Self.kCoach) }
    }
    @Published var studentToken: String? {
        didSet { UserDefaults.standard.set(studentToken, forKey: Self.kStudent) }
    }
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.kBase) }
    }

    init() {
        let d = UserDefaults.standard
        coachCookie = d.string(forKey: Self.kCoach)
        studentToken = d.string(forKey: Self.kStudent)
        baseURL = d.string(forKey: Self.kBase) ?? "https://fit.tianli.cyou"
    }

    var isCoach: Bool { coachCookie != nil }
    var isStudent: Bool { studentToken != nil }

    func signOut() { coachCookie = nil }
    func leaveStudent() { studentToken = nil }

    /// 学员端凭证 = 那条分享链接本身。教练发过来的是整条 URL，这里允许直接粘。
    /// 形如 https://fit.tianli.cyou/s/<token> → 取最后一段；已经是裸 token 则原样。
    static func extractToken(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: "/s/") else { return s }
        return String(s[r.upperBound...])
            .split(separator: "?").first.map(String.init)?
            .split(separator: "#").first.map(String.init) ?? ""
    }
}

@MainActor
final class API {
    private let session: Session
    /// 一次性凭证覆盖：登录前要拿「还没存下来的」学员 token 先试打一发。
    /// **不能**为此临时 new 一个 Session —— Session 的 didSet 会写 UserDefaults，
    /// 那等于「还没验就已经存进去了」。踩过一次，这个覆盖参数就是为它留的。
    private let studentTokenOverride: String?
    init(_ s: Session, studentToken: String? = nil) {
        session = s
        studentTokenOverride = studentToken
    }

    private var urlSession: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false          // cookie 由我们自己拼，见 Session 注释
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    private func makeURL(_ path: String, _ query: [String: String]) throws -> URL {
        guard var comp = URLComponents(string: session.baseURL.trimmingCharacters(in: .whitespaces) + path)
        else { throw APIError.transport("服务器地址不合法：\(session.baseURL)") }
        let items = query.filter { !$0.value.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        if !items.isEmpty { comp.queryItems = items.sorted { $0.name < $1.name } }
        guard let u = comp.url else { throw APIError.transport("URL 拼装失败") }
        return u
    }

    /// 表单编码。后端全站收 Form（`application/x-www-form-urlencoded`），
    /// 发 JSON body 会 422，而 422 在客户端看起来像「密码错了」——踩过，别改成 JSON。
    private func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let enc = { (s: String) in
            s.addingPercentEncoding(withAllowedCharacters: allowed)?
                .replacingOccurrences(of: " ", with: "+") ?? ""
        }
        return fields.map { "\(enc($0.key))=\(enc($0.value))" }
            .joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private func run(_ req: URLRequest) async throws -> (Data, Int) {
        do {
            let (d, r) = try await urlSession.data(for: req)
            return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    private func authed(_ url: URL, student: Bool = false) -> URLRequest {
        var req = URLRequest(url: url)
        if student {
            if let t = studentTokenOverride ?? session.studentToken {
                req.setValue(t, forHTTPHeaderField: "X-Student-Token")
            }
        } else if let c = session.coachCookie {
            req.setValue("\(Session.coachCookieName)=\(c)", forHTTPHeaderField: "Cookie")
        }
        return req
    }

    private func decodeError(_ data: Data, _ code: Int) -> APIError {
        let m = try? JSONDecoder().decode(MutationResp.self, from: data)
        switch code {
        case 404: return .gone
        case 401: return .unauthorized(m?.error ?? "登录失败")
        case 409: return .needsForce(m?.warnings ?? [])
        default:
            if let e = m?.error, !e.isEmpty { return .rejected(e) }
            return .rejected("请求失败（HTTP \(code)）")
        }
    }

    // ── 读 ────────────────────────────────────────────────────────────────

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], student: Bool = false) async throws -> T {
        let (data, code) = try await run(authed(try makeURL(path, query), student: student))
        guard (200..<300).contains(code) else { throw decodeError(data, code) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decode("\(path)：\(error)") }
    }

    // ── 写 ────────────────────────────────────────────────────────────────

    /// 写路径统一出口。409 会抛 `.needsForce`，调用方决定是否带 force 重试。
    @discardableResult
    func post(_ path: String, _ fields: [String: String]) async throws -> MutationResp {
        var req = authed(try makeURL(path, [:]))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(fields)
        let (data, code) = try await run(req)
        guard (200..<300).contains(code) else { throw decodeError(data, code) }
        do { return try JSONDecoder().decode(MutationResp.self, from: data) }
        catch { throw APIError.decode("\(path)：\(error)") }
    }

    // ── 登录 ──────────────────────────────────────────────────────────────

    struct LoginResp: Codable { let ok: Bool; let cookie: String }

    func login(email: String, password: String) async throws -> String {
        var req = URLRequest(url: try makeURL("/api/login", [:]))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(["email": email, "password": password])
        let (data, code) = try await run(req)
        guard (200..<300).contains(code) else { throw decodeError(data, code) }
        guard let r = try? JSONDecoder().decode(LoginResp.self, from: data), r.ok else {
            throw APIError.decode("登录响应异常")
        }
        return r.cookie
    }

    struct Ping: Codable { let ok: Bool; let today: String; let now: String }
    func ping() async throws -> Ping { try await get("/coach/api/ping") }
}

// ── 便捷：把「四位小数的分」与人看的元互转 ─────────────────────────────────

enum Money {
    static func yuan(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100.0)
    }
    static func yuanShort(_ cents: Int) -> String {
        cents % 100 == 0 ? "\(cents / 100)" : yuan(cents)
    }
}
