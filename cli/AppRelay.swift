import Foundation

/// `fitcoach config | update | app …`：转给已装的 Mac 版 App 自己的可执行文件去做（Sources/AppCommand.swift）。
/// 这三组读写的是 App 沙盒容器里的偏好与登录态、App 自己钥匙串里记住的账号密码、iCloud Drive 更新目录的授权，
/// 命令行进程够不着；App 的可执行文件认出命令就做完退出，不开窗口、不进 Dock。
/// 输出与退出码原样带回（共用命令层的约定：0 成功 · 1 未完成 · 2 用法错误或缺 --yes）。
/// 只有两处由这边代办文件读写，因为沙盒里的进程读写不了任意路径：
///   config export -o <file>   让 App 把配置写到标准输出，这边落盘
///   config import <file>      这边读文件，经标准输入递给 App
enum AppRelay {
    static let verbs: Set<String> = ["config", "update", "app"]
    static let bundleID = "cyou.tianli.fitcoachapp"
    /// 与 Sources/AppCommand.swift 的 relayMarker 同一串字：App 可执行文件里有它才转调，
    /// 否则装着的是没有命令入口的旧版，转过去会把窗口打开。
    static let marker = "fitcoach.app-command.v1"

    static func run(_ arguments: [String]) -> Never {
        let json = arguments.contains("--json")
        let words = arguments.filter { !$0.hasPrefix("-") }
        let name = words.prefix(words.first == "app" ? 3 : 2).joined(separator: " ")
        if arguments.contains("--base") || arguments.contains(where: { $0.hasPrefix("--base=") }) {
            fail(2, "usage", "\(words.first ?? "") 读写的是 Mac 版 App 自己保存的设置，不接受 --base；"
                + "App 连哪台服务器用 config status / export / import 读写（fitcoach.baseURL），--base 只管命令行自己这一次连哪台", name, json)
        }
        let executable = locate(name, json)
        if words.count >= 2, words[0] == "config", words[1] == "export", let target = output(arguments), target != "-" {
            export(executable, arguments, target: target, name: name, json: json)
        }
        if words.count == 3, words[0] == "config", words[1] == "import" {
            let url = URL(fileURLWithPath: (words[2] as NSString).expandingTildeInPath)
            guard let data = FileManager.default.contents(atPath: url.path) else { fail(1, "not_found", "没有文件 \(url.path)", name, json) }
            var forwarded = arguments.map { $0 == words[2] ? url.path : $0 }
            forwarded.append("--relay-stdin")
            exit(spawn(executable, forwarded, input: data).status)
        }
        exit(spawn(executable, arguments).status)
    }

    // MARK: 找到 App

    /// FITCOACH_APP（.app 或可执行文件，测试与指定副本用）→ 本命令所在的 .app → 「应用程序」里装着的那份。
    private static func locate(_ name: String, _ json: Bool) -> URL {
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["FITCOACH_APP"], !explicit.isEmpty {
            candidates = [URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)]
        } else {
            var own = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            while own.path != "/" {
                if own.pathExtension == "app" { candidates.append(own); break }
                own.deleteLastPathComponent()
            }
            candidates.append(URL(fileURLWithPath: "/Applications/上门体育.app"))
            candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/上门体育.app"))
        }
        var seen = "没有找到已装的 Mac 版「上门体育」"
        for candidate in candidates {
            var executable = candidate, version = ""
            if candidate.pathExtension == "app" {
                guard let info = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")),
                      info["CFBundleIdentifier"] as? String == bundleID, let binary = info["CFBundleExecutable"] as? String else { continue }
                executable = candidate.appendingPathComponent("Contents/MacOS/" + binary)
                version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
            }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
            guard let bytes = try? Data(contentsOf: executable, options: .mappedIfSafe), bytes.range(of: Data(marker.utf8)) != nil else {
                seen = "\(candidate.path) \(version)还没有命令入口（旧版）：装上带命令入口的 Mac 版后可用"
                continue
            }
            return executable
        }
        fail(1, seen.hasPrefix("没有找到") ? "app_missing" : "app_outdated",
             seen + "。config / update / app 由 Mac 版 App 自己的可执行文件执行（FITCOACH_APP 可指定 .app）", name, json)
    }

    // MARK: 转调

    private static func spawn(_ executable: URL, _ arguments: [String], input: Data? = nil, capture: Bool = false) -> (status: Int32, out: Data, err: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        if capture { process.standardOutput = stdout; process.standardError = stderr }
        do { try process.run() } catch {
            let message = "启动不了 \(executable.path)：\(error.localizedDescription)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return (1, Data(), Data(message.utf8))
        }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        var out = Data(), err = Data()
        if capture {
            // 两条管道分头读完，哪条先写满都不会卡住子进程。
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) { err = stderr.fileHandleForReading.readDataToEndOfFile() }
            out = stdout.fileHandleForReading.readDataToEndOfFile()
            group.wait()
        }
        // 不设超时：update install 核对大发行包可以跑几分钟。
        process.waitUntilExit()
        return (process.terminationReason == .exit ? process.terminationStatus : 1, out, err)
    }

    private static func output(_ arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "-o" || argument == "--output" { return index + 1 < arguments.count ? arguments[index + 1] : nil }
            if argument.hasPrefix("--output=") { return String(argument.dropFirst("--output=".count)) }
        }
        return nil
    }

    /// 与共用层 `config export -o <file>` 同一套检查、同一份结果字段；文件由这边写。
    private static func export(_ executable: URL, _ arguments: [String], target: String, name: String, json: Bool) -> Never {
        let known: Set<String> = ["--json", "--force", "-o", "--output", target, "config", "export"]
        if let stray = arguments.first(where: { !known.contains($0) && !$0.hasPrefix("--output=") }) {
            fail(2, "usage", stray.hasPrefix("-") ? "未知参数 \(stray)" : "用法：fitcoach config export -o <file.json> [--force] [--json]", name, json)
        }
        let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        guard arguments.contains("--force") || !FileManager.default.fileExists(atPath: url.path) else {
            fail(2, "file_exists", "\(url.path) 已存在；加 --force 覆盖", name, json)
        }
        let result = spawn(executable, ["config", "export", "-o", "-"], capture: true)
        guard result.status == 0 else {
            let reason = String(decoding: result.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            fail(result.status, result.status == 2 ? "usage" : "export_failed", reason.isEmpty ? "导出未完成" : reason, name, json)
        }
        // 共用层往标准输出写的是配置本身再加一个换行；落盘的是配置本身。
        var data = result.out
        if data.last == UInt8(ascii: "\n") { data.removeLast() }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail(1, "export_failed", "导出未完成：App 给出的不是一份配置", name, json)
        }
        do { try data.write(to: url, options: .atomic) }
        catch { fail(1, "export_failed", "导出未完成：" + error.localizedDescription, name, json) }
        let keys = ((object["values"] as? [String: Any]) ?? [:]).keys.sorted()
        if json { emit(["ok": true, "command": name, "path": url.path, "bytes": data.count, "keys": keys]) }
        else { print("配置已导出：\(url.path)") }
        exit(0)
    }

    // MARK: 输出（共用命令层的形状）

    private static func emit(_ body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data("{\"ok\":false}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func fail(_ status: Int32, _ code: String, _ message: String, _ name: String, _ json: Bool) -> Never {
        if json { emit(["ok": false, "command": name, "error": ["code": code, "message": message]]) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        exit(status)
    }
}
