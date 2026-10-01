import Foundation

struct SyncEvent: Identifiable, Codable, Sendable {
    var id = UUID()
    var platform: CreditPlatform
    var date: Date
    var message: String
    var endpoint: String?
}

/// Only route names and status codes enter request diagnostics, never headers, bodies or query strings.
struct BillingRequestEvent: Sendable {
    enum Phase: Sendable { case started, response, retry, networkError }
    var phase: Phase
    var endpoint: String
    var message: String
    var statusCode: Int?
}

enum DiagnosticText {
    static func redact(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[已隱藏金鑰]")
        }
        let patterns = [
            #"\b(?:sk-|xi-|lov_|gh[opusr]_)[A-Za-z0-9_-]{12,}"#,
            #"(?i)Bearer\s+[^\s\"<>]+"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            #"(?s)-----BEGIN (?:RSA )?PRIVATE KEY-----.*?-----END (?:RSA )?PRIVATE KEY-----"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[已隱藏憑證]", options: .regularExpression)
        }
        return String(result.prefix(600))
    }
}
