#if os(macOS)
import AppKit
import Foundation
import Security

/// Mac 版 App 可执行文件的命令入口：`fitcoach` 把 config / update / app 原样转到这里
/// （`Contents/MacOS/FitCoach config status --json`，转调在 cli/AppRelay.swift）。沙盒容器里的偏好与登录态、
/// App 自己钥匙串里记住的账号密码、iCloud Drive 更新目录的授权都只在 App 自己手里，所以由这个可执行文件读写；
/// 命令进程不开窗口、不进 Dock、不弹任何框。
///
/// - config：总部共用命令层 `AppLifecycleCLI`，与「配置与更新」面板是同一个 `AppConfiguration`。
/// - update：面板在 Mac 上读更新用的是沙盒目录授权（`MacSandboxUpdateAccess`），共用层的 `update` 走不到它，
///   所以这里用面板同一条读取与校验，输出沿用共用层的字段名。沙盒里的 App 换不了自己：`install` 做到面板
///   「打开发行包」之前那一步（核对发行包身份、大小与 SHA256），然后以 `manual_install` 给出发行包位置。
/// - app saved-login status / clear、app logout：登录窗口「记住账号和密码」存的那份、窗口里的「退出」。
@MainActor
enum AppCommand {
    static let command = "fitcoach"
    static let verbs = ["config", "update", "app"]
    /// `fitcoach` 转调前在 App 可执行文件里找这串字：找不到说明装着的是没有命令入口的旧版，转过去会打开窗口。
    static let relayMarker = "fitcoach.app-command.v1"
    /// `fitcoach config import` 把文件内容从标准输入递进来（沙盒里的进程读不到任意路径）。只给转调用，不进帮助。
    static let relayStdin = "--relay-stdin"
    /// 命令改了运行中的窗口也该跟着变的东西时发这条通知（沙盒里只能带一个字符串，不带字典）。
    static let followName = Notification.Name("cyou.tianli.fitcoachapp.command")

    /// 不是命令返回 nil，照常进界面。App 自己的启动参数都以 `-` 开头，不会撞上这几个动词。
    static func run(_ arguments: [String]) -> Int32? {
        guard let verb = arguments.first, verbs.contains(verb) else { return nil }
        if verb == "config" { return config(arguments) }
        let json = arguments.contains("--json")
        let name = arguments.prefix(3).filter { !$0.hasPrefix("-") }.joined(separator: " ")
        do {
            let parsed = try parse(Array(arguments.dropFirst()))
            let out: (body: [String: Any], text: String)
            switch (verb, parsed.positionals) {
            case ("update", ["check"]): out = try updateCheck()
            case ("update", ["install"]): out = try updateInstall(parsed)
            case ("app", ["protocol"]): out = (["protocol": relayMarker], relayMarker)
            case ("app", ["saved-login", "status"]): out = try savedLoginStatus()
            case ("app", ["saved-login", "clear"]): out = try savedLoginClear(parsed)
            case ("app", ["logout"]): out = try logout(parsed)
            default: throw Failure.usage(syntax)
            }
            var body = out.body
            body["ok"] = true; body["command"] = name
            emit(body, text: out.text, json: json)
            return 0
        } catch let failure as Failure {
            let error: [String: Any] = ["code": failure.code, "message": failure.message]
            var body = failure.extra
            body["ok"] = false; body["command"] = name; body["error"] = error
            if json { emit(body, text: "", json: true) }
            else { FileHandle.standardError.write(Data((failure.message + "\n").utf8)) }
            return failure.exit
        } catch {
            let message = error.localizedDescription
            if json { emit(["ok": false, "command": name, "error": ["code": "failed", "message": message]], text: "", json: true) }
            else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
            return 1
        }
    }

    static let syntax = "用法：\(command) config status | export -o <file> | import <file> --yes | sync on|off --yes；"
        + "\(command) update check | install --yes [--dry-run]；\(command) app saved-login status | clear --yes [--all]；"
        + "\(command) app logout --yes（都可加 --json）"

    // MARK: config

    private static var product: AppLifecycleCLI.Product {
        var product = AppLifecycleCLI.Product(command: command, name: "上门体育", configuration: MobileProductLifecycle.configuration,
                                              updateSource: .privateCloud(channel: MobileProductLifecycle.macChannel), windowEntry: "配置与更新")
        // 导入或同步之后、命令退出之前：校验服务器地址，换了服务器就清掉原服务器的登录态（只拨开关、地址没变时什么都不动）。
        // 开着的窗口另由 follow 跟上；App 没开着时只有这里做。
        product.changed = {
            MobileProductLifecycle.applyPortableConfiguration()
            UserDefaults.standard.synchronize()
        }
        return product
    }

    private static func config(_ arguments: [String]) -> Int32 {
        var arguments = arguments, product = product
        guard let flag = arguments.firstIndex(of: relayStdin) else { return AppLifecycleCLI.run(arguments, product: product) }
        // 转调来的导入：文件内容在标准输入里。先落到 App 自己的临时目录（沙盒里读得到），共用层照常读它；
        // 输出里把这个临时路径换回本人给的那个路径。
        arguments.remove(at: flag)
        let words = arguments.indices.filter { !arguments[$0].hasPrefix("-") }
        guard words.count == 3, arguments[words[1]] == "import" else { return AppLifecycleCLI.run(arguments, product: product) }
        let original = arguments[words[2]]
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("fitcoach-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staged) }
        do { try FileHandle.standardInput.readDataToEndOfFile().write(to: staged, options: .atomic) }
        catch {
            let message = "导入未完成，原配置已保留：" + error.localizedDescription
            if arguments.contains("--json") {
                emit(["ok": false, "command": "config import", "error": ["code": "failed", "message": message]], text: "", json: true)
            } else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
            return 1
        }
        arguments[words[2]] = staged.path
        let out = product.out, err = product.err
        product.out = { out($0.replacingOccurrences(of: staged.path, with: original)) }
        product.err = { err($0.replacingOccurrences(of: staged.path, with: original)) }
        return AppLifecycleCLI.run(arguments, product: product)
    }

    // MARK: update

    private static var current: (version: String, build: String, bundleID: String) {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0", Bundle.main.bundleIdentifier ?? "")
    }
    private static var running: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { $0.processIdentifier != own }
    }
    private static var isolated: Bool { ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil }

    private struct Checked { let release: AppRelease; let state: String; let message: String; let body: [String: Any] }
    /// 面板「检查更新」那一次读取：同一个目录授权、同一份发行记录校验、同样的三种结论。
    private static func checked() throws -> Checked {
        let now = current, channel = MobileProductLifecycle.macChannel
        let base: [String: Any] = ["current": ["version": now.version, "build": now.build],
                                   "source": ["kind": "private_cloud", "channel": channel, "access": "sandbox_bookmark"], "app_running": running]
        let found = Box<Result<AppRelease, Error>>()
        MacSandboxUpdateAccess.check(bundleID: now.bundleID, channel: channel) { found.set($0) }
        spin(30) { found.value != nil }
        let release: AppRelease
        switch found.value {
        case .success(let value)?: release = value
        case .failure(let error)?: throw Failure(exit: 1, code: "check_incomplete", message: "检查未完成：" + error.localizedDescription, extra: base)
        case nil: throw Failure(exit: 1, code: "check_incomplete", message: "检查未完成：30 秒内没有读到发行记录", extra: base)
        }
        let state: String, message: String
        if release.isNewer(than: now.version, build: now.build) {
            state = "update_available"; message = "有新版 \(release.version) (\(release.build))，当前 \(now.version) (\(now.build))。升级会保留本机配置。"
        } else if AppVersion.compare(now.version, release.version) == .orderedDescending {
            state = "ahead_of_channel"; message = "当前 \(now.version) (\(now.build))；此渠道正式发行版本为 \(release.version) (\(release.build))。"
        } else { state = "up_to_date"; message = "当前已是此渠道最新版：\(now.version) (\(now.build))。" }
        let latest: [String: Any] = ["version": release.version, "build": release.build, "channel": release.channel ?? NSNull(),
                                     "package": release.downloadURL?.path ?? NSNull(), "sha256": release.sha256 ?? NSNull(),
                                     "size_bytes": release.size ?? NSNull(), "installation": release.installation ?? NSNull()]
        return Checked(release: release, state: state, message: message,
                       body: base.merging(["latest": latest, "update_available": state == "update_available", "state": state, "message": message]) { $1 })
    }

    private static let manual = "沙盒里的 App 换不了自己：发行包是需要手动安装的 ZIP，解开后把「上门体育」放进「应用程序」替换旧版，配置与登录保留。"
    private static func updateCheck() throws -> ([String: Any], String) {
        let check = try checked(), newer = check.state == "update_available"
        let how = newer ? "运行 \(command) update install --yes 核对发行包（身份、大小、SHA256）并给出位置；或在 App 的「配置与更新」里点「打开发行包」。\(manual)" : "不需要升级。"
        var body = check.body
        let button: Any = newer ? "打开发行包" : NSNull(), install: Any = newer ? "\(command) update install --yes" : NSNull()
        body["upgrade"] = ["in_app": false, "button": button, "how": how, "download_url": NSNull(), "command": install] as [String: Any]
        return (body, check.message + (newer ? "\n" + how : ""))
    }

    private static func updateInstall(_ p: Arguments) throws -> ([String: Any], String) {
        let check = try checked()
        var body = check.body
        guard check.state == "update_available" else {
            body["installed"] = false
            return (body, check.message + "不需要升级。")
        }
        let now = current, release = check.release
        if p.flags.contains("--dry-run") {
            body["dry_run"] = true; body["installed"] = false; body["installation"] = release.installation ?? NSNull()
            body["would_install"] = ["from": ["version": now.version, "build": now.build], "to": ["version": release.version, "build": release.build]]
            body["will_quit_app"] = false; body["will_relaunch"] = false
            return (body, "有新版 \(release.version) (\(release.build))（未执行）。\(manual)")
        }
        guard p.flags.contains("--yes") else {
            throw Failure(exit: 2, code: "confirmation_required", message: "会核对 iCloud Drive 里的发行包（身份、大小、SHA256）并给出它的位置；不替换 App：确认请加 --yes（或先 --dry-run）")
        }
        // 面板「打开发行包」的校验原样跑一遍；最后那一步「交给系统打开」换成只报告位置，命令不弹任何窗口。
        let verified = Box<Result<Void, Error>>()
        MacSandboxUpdateAccess.openPackage(release, bundleID: now.bundleID, channel: MobileProductLifecycle.macChannel,
                                           open: { _, finished in finished(true) }) { verified.set($0) }
        spin(300) { verified.value != nil }
        body["installed"] = false
        switch verified.value {
        case .failure(let error)?: throw Failure(exit: 1, code: "upgrade_failed", message: "发行包未通过核对，当前 App 未动：" + error.localizedDescription, extra: body)
        case nil: throw Failure(exit: 1, code: "upgrade_failed", message: "发行包没有在 300 秒内读完，当前 App 未动（可能还没从 iCloud 下载完）", extra: body)
        case .success?: break
        }
        body["package"] = release.downloadURL?.path ?? NSNull(); body["package_verified"] = true
        throw Failure(exit: 1, code: "manual_install",
                      message: "有新版 \(release.version) (\(release.build))，发行包已核对：\(release.downloadURL?.path ?? "")。\(manual)", extra: body)
    }

    // MARK: app saved-login

    private static let savedLoginService = "cyou.tianli.fitcoachapp.saved-login"
    private static var server: String {
        SavedLogin.serverKey(UserDefaults.standard.string(forKey: "fitcoach.baseURL") ?? Session.defaultBaseURL)
    }
    /// 隔离运行（测试）不碰钥匙串：本机重编的包签名对不上，读真实钥匙串会弹「允许访问」框。
    private static func keychainGate() throws {
        guard !isolated else { throw Failure(exit: 1, code: "isolated_run", message: "隔离运行不读写钥匙串") }
    }
    /// 钥匙串里记着哪些服务器（只取条目的属性，不取密码）。
    private static func savedServers() throws -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: savedLoginService,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = value as? [[String: Any]] else {
            throw Failure(exit: 1, code: "keychain_unavailable", message: "读不到 App 钥匙串里记住的登录（\(status)）")
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
    /// 每台服务器记的是哪个账号。密码不出这个函数。
    private static func savedEntries() throws -> [[String: Any]] {
        try savedServers().map { server in
            let email: Any = (try? SavedLogin.load(server: server))?.email ?? NSNull()
            return ["server": server, "email": email]
        }
    }

    private static func savedLoginStatus() throws -> ([String: Any], String) {
        try keychainGate()
        let entries = try savedEntries(), here = server
        let saved = entries.contains { $0["server"] as? String == here }
        let lines = entries.map { "  \($0["server"] ?? "")  \(($0["email"] as? String) ?? "（读不出账号）")" }
        return (["server": here, "saved": saved, "entries": entries, "count": entries.count, "password_shown": false, "app_running": running],
                "记住账号和密码（当前服务器 \(here)）：\(saved ? "已记住" : "没有记住") · 共 \(entries.count) 条" + (lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")))
    }

    private static func savedLoginClear(_ p: Arguments) throws -> ([String: Any], String) {
        let all = p.flags.contains("--all")
        guard p.flags.contains("--yes") else {
            throw Failure(exit: 2, code: "confirmation_required",
                          message: "会清掉这台 Mac 上「上门体育」钥匙串里记住的账号和密码（\(all ? "所有服务器" : "当前服务器")；登录态与云端数据不动，下次登录要重新输入）：确认请加 --yes")
        }
        try keychainGate()
        let here = server, before = try savedServers()
        let targets = all ? before : before.filter { $0 == here }
        do { for target in targets { try SavedLogin.remove(server: target) } }
        catch { throw Failure(exit: 1, code: "keychain_unavailable", message: error.localizedDescription) }
        let remaining = try savedServers()
        follow("saved-login-cleared")
        return (["cleared": targets, "count": targets.count, "remaining": remaining.count, "server": here, "app_running": running,
                 "check_with": "\(command) app saved-login status"],
                targets.isEmpty ? "没有记住的账号和密码可清（\(all ? "所有服务器" : here)），未改动。" : "已清掉记住的账号和密码：\(targets.joined(separator: " "))")
    }

    // MARK: app logout

    /// 窗口里「退出」的同一件事（`Session.signOut()`）：清本机的教练会话与账号名，回到教练登录；学员链接照留。
    private static func logout(_ p: Arguments) throws -> ([String: Any], String) {
        guard p.flags.contains("--yes") else {
            throw Failure(exit: 2, code: "confirmation_required",
                          message: "会退出这台 Mac 上「上门体育」的教练登录（服务器数据、学员链接、记住的账号密码都不动，再次使用要重新登录）：确认请加 --yes")
        }
        let defaults = UserDefaults.standard
        let had = defaults.string(forKey: "fitcoach.coachCookie") != nil
        ["fitcoach.coachCookie", "fitcoach.coachEmail"].forEach(defaults.removeObject(forKey:))
        defaults.set(false, forKey: "fitcoach.studentMode")
        defaults.synchronize()
        follow("logout")
        return (["logged_out": true, "had_session": had, "session_left": defaults.string(forKey: "fitcoach.coachCookie") != nil,
                 "student_link_kept": defaults.string(forKey: "fitcoach.studentToken") != nil, "app_running": running],
                had ? "已退出这台 Mac 上「上门体育」的教练登录。" : "这台 Mac 上的「上门体育」本来就没有教练登录，未改动。")
    }

    /// 窗口开着时让它跟上：它自己把内存里的那一半做完（见 App.swift 的 `.onReceive`）。隔离运行不发。
    private static func follow(_ what: String) {
        guard !isolated else { return }
        DistributedNotificationCenter.default().postNotificationName(followName, object: what, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Plumbing

    struct Failure: Error {
        let exit: Int32, code: String, message: String
        var extra: [String: Any] = [:]
        static func usage(_ message: String) -> Failure { Failure(exit: 2, code: "usage", message: message) }
    }
    private struct Arguments { var positionals: [String] = []; var flags: Set<String> = [] }
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
    }

    private static func parse(_ arguments: [String]) throws -> Arguments {
        var parsed = Arguments()
        for argument in arguments {
            if ["--json", "--yes", "--dry-run", "--all"].contains(argument) { parsed.flags.insert(argument) }
            else if argument.hasPrefix("-") { throw Failure.usage("未知参数 \(argument)。" + syntax) }
            else { parsed.positionals.append(argument) }
        }
        return parsed
    }

    private static func emit(_ body: [String: Any], text: String, json: Bool) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data("{\"ok\":false}".utf8)
        FileHandle.standardOutput.write(json ? data + Data("\n".utf8) : Data((text + "\n").utf8))
    }

    /// 主线程转着 run loop 等：各回调都投回主队列。
    private static func spin(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
}
#endif
