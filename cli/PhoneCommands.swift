import Foundation

/// 短信账号和 App 共用 API.swift。验证码、密码只从 stdin 读；授权与恢复密钥只写本机 0600 文件。
@MainActor
enum PhoneCommands {
    private static func privateFile(_ c: Context, name: String, value: [String: Any]) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(at: c.store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(c.store.directory.path, 0o700)
        let file = c.store.directory.appendingPathComponent(name)
        let temp = c.store.directory.appendingPathComponent(".phone-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.usage("无法创建本机授权文件") }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            try handle.close()
            guard rename(temp.path, file.path) == 0 else { throw Failure.usage("无法保存本机授权文件") }
            return file.path
        } catch { try? manager.removeItem(at: temp); throw error }
    }
    private static func grant(_ a: Args, _ c: Context, option: String = "grant-file") throws -> String {
        let path = try a.required(option)
        let fields = try jsonDictionary(Data(contentsOf: URL(fileURLWithPath: path)))
        guard fields["base"] as? String == c.base, let token = fields["verification_token"] as? String, !token.isEmpty else {
            throw Failure.usage("--\(option) 不是当前服务器的验证码授权文件")
        }
        return token
    }
    private static func envelope(_ a: Args, flag: String, allowed: Set<String>) throws -> [String: Any] {
        guard a.has(flag) else { return [:] }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let fields: [String: Any]
        do { fields = try jsonDictionary(data) } catch { throw Failure.usage("--\(flag) 需要 stdin JSON 对象") }
        guard fields.keys.allSatisfy({ allowed.contains($0) }), fields.values.allSatisfy({ $0 is String }) else {
            throw Failure.usage("--\(flag) 仅接受字符串字段：\(allowed.sorted().joined(separator: ", "))")
        }
        return fields
    }
    private static func publish(_ raw: Data, _ c: Context, consume: [String] = []) throws {
        var value = try jsonDictionary(raw)
        if let key = value.removeValue(forKey: "recovery_key") as? String {
            let id = (value["coach_id"] as? Int).map(String.init) ?? UUID().uuidString
            value["recovery_key_file"] = try privateFile(c, name: "phone-recovery-\(id).json", value: ["base": c.base, "coach_id": value["coach_id"] ?? NSNull(), "recovery_key": key])
        }
        if let cookie = value.removeValue(forKey: "cookie") as? String {
            let email = value["email"] as? String ?? c.store.load(c.base)?.email
            try c.store.save(c.base, Credential(cookie: cookie, email: email, saved_at: TZ.stampString(Date())))
        }
        for path in consume { try? FileManager.default.removeItem(atPath: path) }
        Out.success(value) {
            Out.line(value["message"] as? String ?? "手机账号操作完成；业务数据仍属于原教练账号。")
            if let path = value["recovery_key_file"] as? String { Out.line("一次性恢复密钥已存入 \(path)（0600）。请备份到密码管理器，勿发送给他人。") }
        }
    }
    static func hints(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let r = try await c.anonymous().accountHints()
        Out.success(encodable(r) as? [String: Any] ?? [:]) { Out.line("中国大陆 +86；重发 \(r.hints.resend) 秒，验证码 \(r.hints.ttl) 秒；签名 \(r.hints.sign_name ?? "服务端未返回")") }
    }
    static func account(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let r = try await c.coach().accountInfo()
        Out.success(encodable(r) as? [String: Any] ?? [:]) { Out.line("教练 \(r.coach_id.map(String.init) ?? "未知") · \(r.phone_hint ?? "未绑定手机号")") }
    }
    static func send(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        guard a.has("confirm-send") else { throw Failure(code: "needs_confirm", message: "发送会计费：须带 --confirm-send；只发送到已授权测试号码。", exit: .needsConfirm) }
        let purpose = try a.required("purpose")
        guard ["register", "login", "recover", "bind", "change_old", "change_new", "identity"].contains(purpose) else { throw Failure.usage("不支持的短信用途") }
        let authenticated = ["bind", "change_old", "change_new", "identity"].contains(purpose)
        let api = authenticated ? try c.coach() : c.anonymous()
        let password = a.has("password-stdin") ? try Commands.secret(a, flag: "password-stdin", prompt: "当前密码：") : ""
        let identity = a.value("identity-grant-file") != nil ? try grant(a, c, option: "identity-grant-file") : ""
        let r = try await api.phoneSend(purpose: purpose, phone: a.value("phone") ?? "", requestID: a.required("request-id"), password: password, identityGrant: identity)
        Out.success(encodable(r) as? [String: Any] ?? [:]) { Out.line("供应商已接收发送请求；不代表实际收到。挑战 \(r.challenge_id ?? "缺失")；签名 \(r.hints.sign_name ?? "未返回")") }
    }
    static func verify(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let api = a.has("authenticated") ? try c.coach() : c.anonymous()
        let code = try Commands.secret(a, flag: "code-stdin", prompt: "短信验证码：")
        let token = try await api.phoneVerify(challenge: a.required("challenge"), code: code, authenticated: a.has("authenticated"))
        let path = try privateFile(c, name: "phone-grant-\(UUID().uuidString).json", value: ["base": c.base, "verification_token": token])
        Out.success(["grant_file": path]) { Out.line("验证码已核验。一次性授权存在 \(path)（0600），消费命令使用 --grant-file。") }
    }
    static func register(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        guard a.has("agreed") else { throw Failure.usage("先阅读产品隐私政策，再带 --agreed") }
        let password = a.has("password-stdin") ? try Commands.secret(a, flag: "password-stdin", prompt: "新密码：") : ""
        let raw = try await c.anonymous().accountJSONRaw("/api/phone_register", ["verification_token": grant(a, c), "display_name": a.value("display-name") ?? "", "password": password, "agreed": true])
        try publish(raw, c, consume: [a.required("grant-file")])
    }
    static func login(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        var fields = try envelope(a, flag: "ownership-stdin", allowed: ["password", "recovery_key"])
        fields["verification_token"] = try grant(a, c)
        let raw = try await c.anonymous().accountJSONRaw("/api/phone_login", fields)
        try publish(raw, c, consume: [a.required("grant-file")])
    }
    static func recover(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        guard a.has("secrets-stdin") else { throw Failure.usage("--secrets-stdin 从 stdin JSON 读 new_password 及 recovery_key 或 password 独立证明") }
        var fields = try envelope(a, flag: "secrets-stdin", allowed: ["new_password", "recovery_key", "password"])
        guard let password = fields["new_password"] as? String, !password.isEmpty else { throw Failure.usage("stdin JSON 缺少 new_password") }
        guard (fields["recovery_key"] as? String)?.isEmpty == false || (fields["password"] as? String)?.isEmpty == false else {
            throw Failure.usage("找回始终需要恢复密钥或原登录密码；两者均不可用请联系支持")
        }
        fields["verification_token"] = try grant(a, c)
        let raw = try await c.anonymous().accountJSONRaw("/api/phone_recover", fields)
        try c.store.remove(c.base)
        try publish(raw, c, consume: [a.required("grant-file")])
    }
    static func bind(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let api = try c.coach()
        var fields: [String: Any] = ["phone": try a.required("phone"), "verification_token": try grant(a, c)]
        if a.has("password-stdin") { fields["password"] = try Commands.secret(a, flag: "password-stdin", prompt: "当前密码：") }
        if a.value("old-grant-file") != nil { fields["old_verification_token"] = try grant(a, c, option: "old-grant-file") }
        if a.value("identity-grant-file") != nil { fields["identity_grant"] = try grant(a, c, option: "identity-grant-file") }
        else if let old = fields["old_verification_token"] { fields["identity_grant"] = old }
        let raw = try await api.accountJSONRaw("/coach/api/phone_bind", fields, authenticated: true)
        try publish(raw, c, consume: [a.value("grant-file"), a.value("old-grant-file"), a.value("identity-grant-file")].compactMap { $0 })
    }
    static func setPassword(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let api = try c.coach()
        let password = try Commands.secret(a, flag: "password-stdin", prompt: "新密码：")
        let raw = try await api.accountJSONRaw("/coach/api/password_set", ["new_password": password, "identity_grant": grant(a, c, option: "identity-grant-file")], authenticated: true)
        try publish(raw, c, consume: [a.required("identity-grant-file")])
    }
}
