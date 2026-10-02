import Foundation
import Security

struct GoogleServiceAccount: Decodable, Sendable {
    let projectID: String
    let clientEmail: String
    let privateKey: String
    let tokenURI: String

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case clientEmail = "client_email"
        case privateKey = "private_key"
        case tokenURI = "token_uri"
    }
}

enum GoogleCloudError: LocalizedError {
    case invalidServiceAccount
    case invalidPrivateKey
    case invalidTableName
    case tokenFailed(String)
    case queryFailed(String)
    case queryTimedOut
    case missingResult

    var errorDescription: String? {
        switch self {
        case .invalidServiceAccount: "Service Account JSON 格式不正確"
        case .invalidPrivateKey: "Service Account 私鑰無法讀取"
        case .invalidTableName: "Billing Export 表名格式錯誤，請使用 project.dataset.table"
        case let .tokenFailed(message): "Google 登入失敗：\(message)"
        case let .queryFailed(message): "BigQuery 查詢失敗：\(message)"
        case .queryTimedOut: "BigQuery 查詢逾時，請稍後重試"
        case .missingResult: "BigQuery 沒有回傳可辨識的帳務資料"
        }
    }
}

struct GeminiBigQueryProvider: Sendable {
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    var client = BillingHTTPClient()
    var now: @Sendable () -> Date = { .now }

    func fetchUsage(serviceAccountJSON: String, billingTable: String, since: Date) async throws -> ProviderUsage {
        guard let accountData = serviceAccountJSON.data(using: .utf8),
              let account = try? JSONDecoder().decode(GoogleServiceAccount.self, from: accountData),
              !account.projectID.isEmpty, !account.clientEmail.isEmpty,
              account.tokenURI == Self.tokenEndpoint.absoluteString else {
            throw GoogleCloudError.invalidServiceAccount
        }
        let table = billingTable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTableName(table) else { throw GoogleCloudError.invalidTableName }
        let token = try await accessToken(for: account)
        return try await queryBilling(projectID: account.projectID, table: table, token: token, since: since)
    }

    static func isValidTableName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_]+\.[A-Za-z0-9_]+$"#, options: .regularExpression) != nil
    }

    private func accessToken(for account: GoogleServiceAccount) async throws -> String {
        let issuedAt = Int(now().timeIntervalSince1970)
        let header = ["alg": "RS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "iss": account.clientEmail,
            "scope": "https://www.googleapis.com/auth/bigquery.readonly https://www.googleapis.com/auth/cloud-platform.read-only",
            "aud": Self.tokenEndpoint.absoluteString,
            "iat": issuedAt,
            "exp": issuedAt + 3600
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = "\(headerData.base64URL).\(payloadData.base64URL)"
        guard let key = Self.privateKey(fromPEM: account.privateKey),
              SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256) else {
            throw GoogleCloudError.invalidPrivateKey
        }
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &signingError
        ) as Data? else {
            throw GoogleCloudError.tokenFailed(signingError?.takeRetainedValue().localizedDescription ?? "JWT 簽署失敗")
        }
        let assertion = "\(signingInput).\(signature.base64URL)"
        // Imported JSON must never redirect a signed assertion to another host.
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion.urlQueryEncoded)".data(using: .utf8)
        let data = try await client.data(for: request)
        guard let result = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else {
            throw GoogleCloudError.tokenFailed("Token 回應格式不正確")
        }
        return result.accessToken
    }

    private func queryBilling(projectID: String, table: String, token: String, since: Date) async throws -> ProviderUsage {
        let query = """
        SELECT
          CAST(COALESCE(SUM(cost), 0) AS STRING) AS gross_cost,
          COALESCE(ANY_VALUE(currency), 'USD') AS currency
        FROM `\(table)`
        WHERE usage_start_time >= @start_time
          AND (
            LOWER(service.description) LIKE '%gemini%'
            OR LOWER(service.description) LIKE '%generative language%'
            OR LOWER(sku.description) LIKE '%gemini%'
          )
        """
        let requestBody = BigQueryRequest(
            query: query,
            useLegacySql: false,
            timeoutMs: 30_000,
            parameterMode: "NAMED",
            queryParameters: [
                .init(
                    name: "start_time",
                    parameterType: .init(type: "TIMESTAMP"),
                    parameterValue: .init(value: ISO8601DateFormatter().string(from: since))
                )
            ]
        )
        var request = URLRequest(url: URL(string: "https://bigquery.googleapis.com/bigquery/v2/projects/\(projectID)/queries")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        let data = try await client.data(for: request)
        return try Self.parseBillingResponse(data, fetchedAt: now())
    }

    static func parseBillingResponse(_ data: Data, fetchedAt: Date) throws -> ProviderUsage {
        guard let result = try? JSONDecoder().decode(BigQueryResponse.self, from: data) else {
            throw GoogleCloudError.missingResult
        }
        guard result.jobComplete != false else { throw GoogleCloudError.queryTimedOut }
        if let errors = result.errors, !errors.isEmpty {
            throw GoogleCloudError.queryFailed(errors.compactMap(\.message).joined(separator: "；"))
        }
        guard let fields = result.schema?.fields,
              let values = result.rows?.first?.f else { throw GoogleCloudError.missingResult }
        let row = Dictionary(uniqueKeysWithValues: zip(fields.map(\.name), values.map(\.v)))
        guard let costText = row["gross_cost"],
              let cost = Decimal(string: costText, locale: Locale(identifier: "en_US_POSIX")) else {
            throw GoogleCloudError.missingResult
        }
        return ProviderUsage(platform: .gemini, cumulativeCost: cost, currency: row["currency"] ?? "USD", fetchedAt: fetchedAt)
    }

    static func privateKey(fromPEM pem: String) -> SecKey? {
        let isPKCS8 = pem.contains("-----BEGIN PRIVATE KEY-----")
        let body = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let decoded = Data(base64Encoded: body) else { return nil }
        let data = isPKCS8 ? (Self.pkcs1Data(fromPKCS8: decoded) ?? decoded) : decoded
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }

    static func pkcs1Data(fromPKCS8 data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        guard let outer = readDERElement(bytes, index: &index), outer.tag == 0x30 else { return nil }
        let inner = Array(outer.value)
        var innerIndex = 0
        guard readDERElement(inner, index: &innerIndex)?.tag == 0x02 else { return nil }
        guard readDERElement(inner, index: &innerIndex)?.tag == 0x30 else { return nil }
        guard let privateKey = readDERElement(inner, index: &innerIndex), privateKey.tag == 0x04 else { return nil }
        return Data(privateKey.value)
    }

    private static func readDERElement(_ bytes: [UInt8], index: inout Int) -> (tag: UInt8, value: ArraySlice<UInt8>)? {
        guard index + 2 <= bytes.count else { return nil }
        let tag = bytes[index]
        index += 1
        let firstLength = Int(bytes[index])
        index += 1
        let length: Int
        if firstLength & 0x80 == 0 {
            length = firstLength
        } else {
            let count = firstLength & 0x7f
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            var accumulated = 0
            for _ in 0..<count {
                accumulated = (accumulated << 8) | Int(bytes[index])
                index += 1
            }
            length = accumulated
        }
        guard length >= 0, index + length <= bytes.count else { return nil }
        let value = bytes[index..<(index + length)]
        index += length
        return (tag, value)
    }

    private static func googleErrorMessage(from data: Data) -> String {
        if let response = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data) {
            return response.errorDescription
        }
        return String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "未知錯誤"
    }
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
}

private struct BigQueryRequest: Encodable {
    struct QueryParameter: Encodable {
        struct ParameterType: Encodable { let type: String }
        struct ParameterValue: Encodable { let value: String }
        let name: String
        let parameterType: ParameterType
        let parameterValue: ParameterValue
    }
    let query: String
    let useLegacySql: Bool
    let timeoutMs: Int
    let parameterMode: String
    let queryParameters: [QueryParameter]
}

private struct BigQueryResponse: Decodable {
    struct Field: Decodable { let name: String }
    struct Schema: Decodable { let fields: [Field] }
    struct Cell: Decodable { let v: String }
    struct Row: Decodable { let f: [Cell] }
    struct QueryError: Decodable { let message: String? }
    let jobComplete: Bool?
    let schema: Schema?
    let rows: [Row]?
    let errors: [QueryError]?
}

private struct GoogleErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String?; let status: String? }
    let error: Detail?
    let errorDescriptionValue: String?
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescriptionValue = "error_description"
    }
    var errorDescription: String { error?.message ?? errorDescriptionValue ?? error?.status ?? "未知錯誤" }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
