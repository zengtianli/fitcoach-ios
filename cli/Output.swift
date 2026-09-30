import Foundation

// ── 退出码与失败形态 ────────────────────────────────────────────────────────
// 与后端错误协议（API.swift 的 APIError）一一对应；智能体按退出码分支，不解析文案。

enum ExitCode: Int32 {
    case ok = 0
    case failure = 1        // 网络 / 服务端 5xx（可稍后重试）/ 响应解析 / 本机写凭证失败
    case usage = 2          // 参数错
    case signedOut = 3      // 没登录、登录已失效；学员链接无效或已吊销
    case rejected = 4       // 后端 400：校验不过或硬拒（--force 也不放行）；直接写入的 id 不存在也在这里
    case needsConfirm = 5   // 后端 409 软警告，或本机要求显式确认（--force / --yes / --confirm）
    case authFailed = 6     // 登录失败（401）或尝试过于频繁（429）
    case notFound = 7       // 已登录，但要读的记录不存在（读取与先读后改的 update / edit / --dry-run）
}

struct Failure: Error {
    let code: String
    let message: String
    let exit: ExitCode
    var warnings: [Warn] = []

    static func usage(_ message: String) -> Failure { Failure(code: "usage", message: message, exit: .usage) }
    static let signedOut = Failure(code: "signed_out",
                                   message: "未登录或登录已失效：先运行 fitcoach login --email <邮箱> --password-stdin",
                                   exit: .signedOut)
    static let notFound = Failure(code: "not_found", message: "记录不存在", exit: .notFound)
}

/// APIError → Failure。404 在后端刻意不区分「没过闸」与「记录不存在」，这里再打一发 ping 分辨：
/// ping 也 404 = 登录失效（3），否则 = 记录不存在（7）。只读，不改任何状态。
@MainActor
func classify(_ error: Error, api: API?) async -> Failure {
    if let failure = error as? Failure { return failure }
    guard let apiError = error as? APIError else {
        return Failure(code: "failure", message: error.localizedDescription, exit: .failure)
    }
    switch apiError {
    case .rejected(let message):
        return Failure(code: "rejected", message: message, exit: .rejected)
    case .needsForce(let warnings):
        let text = warnings.map(\.message).joined(separator: "；")
        return Failure(code: "needs_force", message: text + "。确认无误后加 --force 重试",
                       exit: .needsConfirm, warnings: warnings)
    case .gone:
        guard let api else { return .signedOut }
        do {
            _ = try await api.ping()
            return .notFound
        } catch APIError.gone {
            return .signedOut
        } catch {
            return Failure(code: "gone", message: apiError.localizedDescription, exit: .signedOut)
        }
    case .unauthorized(let message):
        return Failure(code: "auth_failed", message: message, exit: .authFailed)
    case .transport:
        return Failure(code: "transport", message: apiError.localizedDescription, exit: .failure)
    case .server(let status, let message):
        return Failure(code: "server_error", message: "\(message)（服务端临时出错 HTTP \(status)，可稍后重试）",
                       exit: .failure)
    case .decode:
        return Failure(code: "decode", message: apiError.localizedDescription, exit: .failure)
    }
}

// ── 输出 ────────────────────────────────────────────────────────────────────

enum Out {
    static var json = false

    /// 一行 JSON 到 stdout（键排序，便于 diff 与 jq）。
    static func emit(_ object: [String: Any]) {
        var decimals: [String] = []
        let marker = "fcnum-" + UUID().uuidString + "-"
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: sanitize(object, marker: marker, into: &decimals),
                                                     options: options),
              let text = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("fitcoach：JSON 输出失败\n".utf8))
            return
        }
        print(decimals.isEmpty ? text : splice(text, marker: marker, decimals: decimals))
    }

    static func line(_ text: String = "") { print(text) }

    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// 成功：--json 时输出 {"ok": true, …payload}；否则执行文本渲染。
    static func success(_ payload: [String: Any], text: () -> Void) {
        if json {
            var object = payload
            object["ok"] = true
            emit(object)
        } else {
            text()
        }
    }

    static func fail(_ failure: Failure) -> Never {
        if json {
            var object: [String: Any] = ["ok": false, "code": failure.code, "error": failure.message]
            if !failure.warnings.isEmpty { object["warnings"] = encodable(failure.warnings) }
            emit(object)
        } else {
            note("fitcoach：\(failure.message)")
            for warning in failure.warnings {
                note("  - [\(warning.code)] \(warning.message)")
            }
        }
        exit(failure.exit.rawValue)
    }

    /// Optional.none 进 JSONSerialization 会炸；统一换成 NSNull。
    /// 小数照后端原文的写法输出：JSONSerialization 会把 12.3 写成 12.300000000000001（17 位有效数字）、
    /// 把 20.0 写成 20，智能体照抄或按类型判断就错了。这里先把每个小数换成占位字符串，序列化后再原样换回
    /// Swift 的最短往返写法（`Double.description`：12.3、20.0、53.10000000000001，与后端 Python 的 repr 同形）。
    /// 整数、布尔原样。
    static func sanitize(_ value: Any, marker: String, into decimals: inout [String]) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in dict { out[key] = sanitize(item, marker: marker, into: &decimals) }
            return out
        case let array as [Any]:
            return array.map { sanitize($0, marker: marker, into: &decimals) }
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), CFNumberIsFloatType(number),
                  number.doubleValue.isFinite else { return number }
            decimals.append(number.doubleValue.description)
            return marker + String(decimals.count - 1)
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                return mirror.children.first.map { sanitize($0.value, marker: marker, into: &decimals) } ?? NSNull()
            }
            return value
        }
    }

    /// 把 `"<marker><序号>"` 换回对应小数的原文（一遍线性扫描）。
    static func splice(_ text: String, marker: String, decimals: [String]) -> String {
        let parts = text.components(separatedBy: "\"" + marker)
        var out = parts[0]
        for part in parts.dropFirst() {
            guard let quote = part.firstIndex(of: "\""), let index = Int(part[..<quote]), decimals.indices.contains(index)
            else { out += "\"" + marker + part; continue }
            out += decimals[index] + part[part.index(after: quote)...]
        }
        return out
    }
}

/// Encodable → JSONSerialization 对象（输出里嵌模型用）。
func encodable<T: Encodable>(_ value: T, snakeCase: Bool = false) -> Any {
    let encoder = JSONEncoder()
    if snakeCase { encoder.keyEncodingStrategy = .convertToSnakeCase }
    guard let data = try? encoder.encode(value),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
        return NSNull()
    }
    return object
}

/// 后端原始 JSON → 字典（--json 原样转发服务端字段，客户端不删改业务数据）。
func jsonDictionary(_ data: Data) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
        throw APIError.decode("响应不是 JSON 对象")
    }
    return dict
}

// ── 文本渲染小工具 ──────────────────────────────────────────────────────────

func number(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
}

func yesNo(_ flag: Bool) -> String { flag ? "有" : "无" }
