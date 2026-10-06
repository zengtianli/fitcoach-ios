import Foundation

/// 命令行自己的登录凭证，与 App 的 UserDefaults / 钥匙串互不相干。
///
/// 存在 `~/Library/Application Support/FitCoach/cli/credentials.json`（目录 0700、文件 0600），
/// 按服务器地址分条；`FITCOACH_CLI_HOME` 可改目录（测试、沙盒）。
/// 不用钥匙串：本机编译的命令行每次重编签名都会变，钥匙串会弹「允许访问」对话框 ——
/// 给智能体驱动的命令行弹窗等于卡死并抢用户焦点。
/// cookie 是后端签名会话；账号版本变化（改密、手机号换绑/找回）使旧会话失效。
/// 成功回执的新 cookie 更新本文件，logout 只删本机这份。
struct Credential: Codable {
    let cookie: String
    let email: String?
    let saved_at: String
}

struct CredentialStore {
    let directory: URL

    var file: URL { directory.appendingPathComponent("credentials.json") }

    static func standard() -> CredentialStore {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["FITCOACH_CLI_HOME"], !custom.isEmpty {
            return CredentialStore(directory: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        return CredentialStore(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FitCoach/cli"))
    }

    private struct Shape: Codable {
        var version = 1
        var accounts: [String: Credential] = [:]
    }

    func load(_ base: String) -> Credential? { read().accounts[base] }

    func save(_ base: String, _ credential: Credential) throws {
        var shape = read()
        shape.accounts[base] = credential
        try write(shape)
    }

    /// 删掉这台服务器的凭证；返回是否真有一条被删。
    @discardableResult
    func remove(_ base: String) throws -> Bool {
        var shape = read()
        guard shape.accounts.removeValue(forKey: base) != nil else { return false }
        if shape.accounts.isEmpty {
            try FileManager.default.removeItem(at: file)
        } else {
            try write(shape)
        }
        return true
    }

    private func read() -> Shape {
        guard let data = try? Data(contentsOf: file),
              let shape = try? JSONDecoder().decode(Shape.self, from: data) else { return Shape() }
        return shape
    }

    /// 先建 0600 的临时文件再写内容、rename 覆盖：任何时刻都不存在别人可读的凭证文件。
    private func write(_ shape: Shape) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(shape)
        let temp = directory.appendingPathComponent(".credentials.\(getpid()).tmp")
        _ = try? manager.removeItem(at: temp)
        guard manager.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(code: "failure", message: "无法写入凭证文件 \(temp.path)", exit: .failure)
        }
        let handle = try FileHandle(forWritingTo: temp)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temp.path, file.path) == 0 else {
            _ = try? manager.removeItem(at: temp)
            throw Failure(code: "failure", message: "无法保存凭证文件 \(file.path)", exit: .failure)
        }
    }
}

/// 从 stdin 读一行（密码 / 学员链接）。只去掉行尾换行，密码里的空格原样保留。
func readStdinLines() -> [String] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
    }
}

/// 终端交互时不回显地读密码；非终端且未给 --password-stdin 时返回 nil（由调用方报用法错）。
func promptSecret(_ prompt: String) -> String? {
    guard isatty(STDIN_FILENO) == 1, let raw = getpass(prompt) else { return nil }
    return String(cString: raw)
}
