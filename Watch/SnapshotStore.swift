import Foundation
import Security

/// 手表 app 与表盘复杂功能**共用的一份**「今天」快照：手表本机钥匙串，不跨设备、不上 iCloud。
///
/// 为什么是钥匙串不是 App Group：App Group 的组要先在开发者门户登记，命令行建不了；keychain access group
/// 不用登记（描述文件默认带 `<TeamID>.*` 通配）。与成长小金库 Snapshot.swift 同一做法：
/// **不传** `kSecAttrAccessGroup`，落在 entitlement 的第一个组 —— Watch.entitlements 与 WatchWidget.entitlements
/// 第一项逐字相同，就是同一个仓，TeamID 一个字都不进源码。
enum SnapshotStore {
    private static let service = "cyou.tianli.fitcoachapp.watch-today"
    private static let account = "current"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> WatchSnapshot? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return WatchSnapshot.decode(d)
    }

    static func save(_ snap: WatchSnapshot) {
        guard let d = snap.encoded() else { return }
        // AfterFirstUnlock：表盘要在手腕放下（设备锁着）时也能画出「下一节」
        let attrs: [String: Any] = [kSecValueData as String: d,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { a, _ in a }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
