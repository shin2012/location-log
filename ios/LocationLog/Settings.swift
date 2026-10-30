import Foundation
import Security

/// 서버 주소·토큰. 토큰은 키체인(잠금 해제 한 번 뒤에는 백그라운드에서도 읽힘)에 보관
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let defaultBaseURL = "https://location.b-612.kr/app-api"

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    @Published var token: String {
        didSet { Keychain.set(token, for: "apiToken") }
    }

    private init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? Self.defaultBaseURL
        token = Keychain.get("apiToken") ?? ""
    }
}

enum Keychain {
    private static let service = "kr.b612.locationlog"

    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
