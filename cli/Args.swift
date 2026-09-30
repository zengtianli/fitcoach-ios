import Foundation

/// 命令行参数：`--名 值`、`--名=值`、布尔开关与位置参数。每条命令声明自己收哪些，
/// 其余一律按用法错误（退出码 2）拒绝 —— 不猜、不静默忽略。
struct Args {
    private(set) var positional: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ tokens: [String], values valueOptions: Set<String>, flags flagOptions: Set<String>) throws {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                positional += tokens[(index + 1)...]
                break
            }
            if token.hasPrefix("--"), token.count > 2 {
                var name = String(token.dropFirst(2))
                var inline: String?
                if let eq = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                }
                if valueOptions.contains(name) {
                    if let inline {
                        values[name] = inline
                    } else {
                        guard index + 1 < tokens.count else { throw Failure.usage("--\(name) 需要一个值") }
                        values[name] = tokens[index + 1]
                        index += 1
                    }
                } else if flagOptions.contains(name) {
                    guard inline == nil else { throw Failure.usage("--\(name) 是开关，不带值") }
                    flags.insert(name)
                } else {
                    throw Failure.usage("不认识的参数 --\(name)（见 --help）")
                }
            } else if token.hasPrefix("-"), token.count > 1, Double(token) == nil {
                throw Failure.usage("不认识的参数 \(token)（见 --help）")
            } else {
                positional.append(token)
            }
            index += 1
        }
    }

    func value(_ name: String) -> String? { values[name] }

    func has(_ name: String) -> Bool { flags.contains(name) }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure.usage("缺少 --\(name)")
        }
        return value
    }

    func int(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        guard let number = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw Failure.usage("--\(name) 须是整数：\(raw)")
        }
        return number
    }

    func requiredInt(_ name: String) throws -> Int {
        guard let number = try int(name) else { throw Failure.usage("缺少 --\(name)") }
        return number
    }

    /// 二选一开关：给了 a → true，给了 b → false，都没给 → nil，都给了 → 用法错。
    func choice(_ a: String, _ b: String) throws -> Bool? {
        switch (has(a), has(b)) {
        case (true, true): throw Failure.usage("--\(a) 与 --\(b) 只能给一个")
        case (true, false): return true
        case (false, true): return false
        default: return nil
        }
    }

    /// 取第 index 个位置参数作整数 id，并确认没有多余的位置参数。
    func id(_ what: String, count: Int = 1) throws -> Int {
        guard positional.count == count else {
            throw Failure.usage(positional.isEmpty ? "缺少\(what) id" : "位置参数个数不对：\(positional.joined(separator: " "))")
        }
        guard let number = Int(positional[0]) else { throw Failure.usage("\(what) id 须是整数：\(positional[0])") }
        return number
    }

    func noPositional() throws {
        guard positional.isEmpty else { throw Failure.usage("多余的参数：\(positional.joined(separator: " "))") }
    }
}
