import Foundation
import Security
import CryptoKit

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidHelper
    case invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidHelper:
            return "金鑰工具缺少或簽署不符。請重新安裝完整的 AI Credits App。"
        case .invalidResponse:
            return "金鑰工具未能完成操作，請重新開啟 AI Credits 後再試。"
        case .status(let code):
            if code == errSecInteractionNotAllowed || code == errSecAuthFailed {
                return "需要 Keychain 鑰匙圈授權。請按「立即測試」，在 macOS 視窗中允許 AICreditsKeychain 存取此平台金鑰；選「永遠允許」可記住授權。背景同步不會跳出密碼視窗。"
            }
            if code == errSecUserCanceled { return "已取消鑰匙圈授權；請準備好後再按「立即測試」。" }
            return "Keychain 錯誤（\(code)）：\(SecCopyErrorMessageString(code, nil) as String? ?? "未知錯誤")"
        }
    }
}

protocol CredentialStore: Sendable {
    func set(_ value: String, for platform: CreditPlatform) throws
    func get(for platform: CreditPlatform, allowInteraction: Bool) throws -> String?
    func delete(for platform: CreditPlatform) throws
}

struct KeychainService: CredentialStore {
    // The helper's exact signed bytes persist across ordinary app updates, including
    // its file-based Keychain partition. Each side verifies the other's signing identity.
    func set(_ value: String, for platform: CreditPlatform) throws {
        _ = try call(operation: "set", platform: platform, value: value, allowInteraction: true)
    }

    func get(for platform: CreditPlatform, allowInteraction: Bool = false) throws -> String? {
        try call(operation: "get", platform: platform, allowInteraction: allowInteraction).value
    }

    func delete(for platform: CreditPlatform) throws {
        _ = try call(operation: "delete", platform: platform, allowInteraction: true)
    }

    private struct Request: Encodable {
        let operation: String
        let account: String
        let value: String?
        let allowInteraction: Bool
    }
    private struct Response: Decodable {
        let status: OSStatus
        let value: String?
    }

    private func call(operation: String, platform: CreditPlatform, value: String? = nil, allowInteraction: Bool) throws -> Response {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/AICreditsKeychain")
        try verify(helper)
        let request = Request(operation: operation, account: platform.rawValue, value: value, allowInteraction: allowInteraction)
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // No credential is put in command-line arguments, environment variables or logs.
        do { try process.run() } catch { throw KeychainError.invalidHelper }
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
            try input.fileHandleForWriting.close()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                throw KeychainError.invalidResponse
            }
            guard response.status == errSecSuccess else { throw KeychainError.status(response.status) }
            guard process.terminationStatus == 0 else { throw KeychainError.invalidResponse }
            return response
        } catch let error as KeychainError { throw error }
        catch { throw KeychainError.invalidResponse }
    }

    private func verify(_ helper: URL) throws {
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
              SecCodeCopySigningInformation(ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { throw KeychainError.invalidHelper }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }.joined()
        let text = "identifier \"com.local.AICredits.keychain\" and certificate leaf = H\"\(fingerprint)\""
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw KeychainError.invalidHelper
        }
    }
}
