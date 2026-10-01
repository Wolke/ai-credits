import Foundation
import Security

#if REAL_CLIENT
// Compile the production KeychainService with a test-only account enum.
enum CreditPlatform: String, Sendable { case probe = "SigningProbe" }
let service = KeychainService()
let operation = CommandLine.arguments[2]
let expected = "AI Credits signing continuity test"
do {
    switch operation {
    case "set": try service.set(expected, for: .probe)
    case "get":
        guard try service.get(for: .probe, allowInteraction: false) == expected else { exit(6) }
    case "delete": try service.delete(for: .probe)
    case "blocked":
        _ = try service.get(for: .probe, allowInteraction: false)
        exit(7)
    default: exit(2)
    }
} catch KeychainError.status(let status) where operation == "blocked" && [errSecInteractionNotAllowed, errSecAuthFailed].contains(status) {
    print("Unauthorized background access returned OSStatus \(status) without UI")
} catch {
    print("Production Keychain client failed: \(error.localizedDescription)")
    exit(8)
}
print("Production client \(operation): passed")
#else

// Integration test: uses only the reserved SigningProbe account, never real API keys.
let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(2) }
let helper = URL(fileURLWithPath: arguments[1])
let operation = arguments[2]
let expected = "AI Credits signing continuity test"
if operation == "seed-legacy" || operation == "cleanup-legacy" {
    SecKeychainSetUserInteractionAllowed(false)
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.local.AICredits.credentials.v2",
        kSecAttrAccount as String: "SigningProbe"
    ]
    let status: OSStatus
    if operation == "seed-legacy" {
        query[kSecValueData as String] = Data(expected.utf8)
        status = SecItemAdd(query as CFDictionary, nil)
    } else { status = SecItemDelete(query as CFDictionary) }
    guard status == errSecSuccess else { print("Legacy fixture failed: \(status)"); exit(9) }
    exit(0)
}
let request: [String: Any] = [
    "operation": operation,
    "account": "SigningProbe",
    "value": expected,
    "allowInteraction": false
]
let process = Process()
let input = Pipe(), output = Pipe()
process.executableURL = helper
process.standardInput = input
process.standardOutput = output
process.standardError = FileHandle.nullDevice
try process.run()
try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
try input.fileHandleForWriting.close()
let response = try output.fileHandleForReading.readToEnd() ?? Data()
process.waitUntilExit()
guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any],
      let status = result["status"] as? Int else { exit(3) }
if operation == "rejected" {
    guard status == -25293 else { exit(4) }
} else {
    guard status == 0 else { print("Probe \(operation) failed: OSStatus \(status)"); exit(5) }
    if operation == "get", result["value"] as? String != expected { exit(6) }
}
print("Probe \(operation): passed (no authentication UI)")
#endif
