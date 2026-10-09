import Foundation
import Security

/// API Key 存在系統 Keychain，不寫進設定檔。
/// iOS 上只有主 App 會讀（鍵盤擴充不碰網路，也就不需要金鑰）。
public enum Keychain {
    public enum Kind: String, Sendable { case stt, llm }

    static let service = "tapsay"

    private static func query(_ kind: Kind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }

    public static func get(_ kind: Kind) -> String {
        var q = query(kind)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 空字串＝刪除。
    @discardableResult
    public static func set(_ kind: Kind, _ value: String) -> Bool {
        let q = query(kind)
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        #if os(iOS)
        // 鍵盤觸發錄音時 App 在背景、手機可能是鎖定的，所以不能用 WhenUnlocked。
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func has(_ kind: Kind) -> Bool { !get(kind).isEmpty }
}
