import Foundation
import Security
import LocalAuthentication

enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        if statusCode == errSecInteractionNotAllowed || statusCode == errSecAuthFailed {
            return "無法讀取 Keychain 金鑰。請解鎖登入鑰匙圈，再按「立即同步」允許此 App 存取，或於設定重新儲存金鑰。"
        }
        return "Keychain 錯誤（\(statusCode)）：\(SecCopyErrorMessageString(statusCode, nil) as String? ?? "未知錯誤")"
    }
    private var statusCode: OSStatus { if case let .status(code) = self { code } else { 0 } }
}

protocol CredentialStore: Sendable {
    func set(_ value: String, for platform: CreditPlatform) throws
    func get(for platform: CreditPlatform, allowInteraction: Bool) throws -> String?
    func delete(for platform: CreditPlatform) throws
}

struct KeychainService: CredentialStore {
    // v2 starts with the stable designated requirement used by build-app.sh.
    private let service = "com.local.AICredits.credentials.v2"

    func set(_ value: String, for platform: CreditPlatform) throws {
        let account = platform.rawValue
        let context = authenticationContext(allowInteraction: true)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context
        ]
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }
        var query = base
        query.removeValue(forKey: kSecUseAuthenticationContext as String)
        query[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func get(for platform: CreditPlatform, allowInteraction: Bool = false) throws -> String? {
        let context = authenticationContext(allowInteraction: allowInteraction)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: platform.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    func delete(for platform: CreditPlatform) throws {
        let context = authenticationContext(allowInteraction: true)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: platform.rawValue,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    private func authenticationContext(allowInteraction: Bool) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        return context
    }
}
