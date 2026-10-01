import Foundation

struct ProviderUsage: Sendable {
    let platform: CreditPlatform
    let cumulativeCost: Decimal
    let currency: String
    let fetchedAt: Date
}

protocol CreditProvider: Sendable {
    var platform: CreditPlatform { get }
    func fetchUsage(apiKey: String, since: Date) async throws -> ProviderUsage
}

enum ProviderError: LocalizedError {
    case invalidResponse
    case http(Int, String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "平台回傳無法辨識或不完整的資料，未更新額度"
        case let .http(code, message):
            "HTTP \(code)：\(message)" + ([401, 403].contains(code) ? "；請確認金鑰有效且具有帳務／使用者讀取權限" : "")
        case .unsupported: "此平台目前只支援手動更新"
        }
    }
}

/// Billing reads must bypass URL caches. Retry only transient failures, never invalid credentials.
struct BillingHTTPClient: Sendable {
    var session: URLSession = .shared
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }

    func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        for attempt in 0...2 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
                if (200..<300).contains(http.statusCode) { return data }
                if ([408, 429].contains(http.statusCode) || (500..<600).contains(http.statusCode)), attempt < 2 {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    try await sleep(min(30, max(1, retryAfter ?? pow(2, Double(attempt)))))
                    continue
                }
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let detail = (object?["error"] ?? object?["detail"]) as? [String: Any]
                let message = detail?["message"] as? String ?? object?["detail"] as? String
                    ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                throw ProviderError.http(http.statusCode, String(message.prefix(250)))
            } catch let error as URLError where attempt < 2 && [
                .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
            ].contains(error.code) {
                try await sleep(pow(2, Double(attempt)))
            }
        }
        throw ProviderError.invalidResponse
    }
}

struct OpenAIProvider: CreditProvider {
    let platform: CreditPlatform = .openAI
    var client = BillingHTTPClient()
    var now: @Sendable () -> Date = { .now }

    func fetchUsage(apiKey: String, since: Date) async throws -> ProviderUsage {
        let end = now()
        let query: [URLQueryItem] = [
            .init(name: "start_time", value: String(Int(since.timeIntervalSince1970))),
            .init(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "180")
        ]
        var cursor: String?
        var seenCursors = Set<String>()
        var total = Decimal.zero
        var currency: String?
        repeat {
            var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
            components.queryItems = query + (cursor.map { [.init(name: "page", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let data = try await client.data(for: request)
            let page = try JSONDecoder().decode(OpenAICostPage.self, from: data)
            for result in page.data.flatMap(\.results) {
                let unit = result.amount.currency.uppercased()
                guard currency == nil || currency == unit else { throw ProviderError.invalidResponse }
                currency = unit
                total += result.amount.value
            }
            cursor = try nextCursor(hasMore: page.has_more, nextPage: page.next_page, seen: &seenCursors)
        } while cursor != nil
        return ProviderUsage(platform: platform, cumulativeCost: total, currency: currency ?? "USD", fetchedAt: end)
    }
}

private struct OpenAICostPage: Decodable {
    struct Bucket: Decodable { let results: [Result] }
    struct Result: Decodable { let amount: Amount }
    struct Amount: Decodable { let value: Decimal; let currency: String }
    let data: [Bucket]
    let has_more: Bool
    let next_page: String?
}

struct ClaudeProvider: CreditProvider {
    let platform: CreditPlatform = .claude
    var client = BillingHTTPClient()
    var now: @Sendable () -> Date = { .now }

    func fetchUsage(apiKey: String, since: Date) async throws -> ProviderUsage {
        let end = now()
        let formatter = ISO8601DateFormatter()
        let query: [URLQueryItem] = [
            .init(name: "starting_at", value: formatter.string(from: since)),
            .init(name: "ending_at", value: formatter.string(from: end)),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31")
        ]
        var cursor: String?
        var seenCursors = Set<String>()
        var totalMinor = Decimal.zero
        repeat {
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            components.queryItems = query + (cursor.map { [.init(name: "page", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let data = try await client.data(for: request)
            let page = try JSONDecoder().decode(ClaudeCostReport.self, from: data)
            totalMinor += page.data.flatMap(\.results).reduce(Decimal.zero) { $0 + $1.amount }
            cursor = try nextCursor(hasMore: page.has_more, nextPage: page.next_page, seen: &seenCursors)
        } while cursor != nil
        return ProviderUsage(platform: platform, cumulativeCost: totalMinor / 100, currency: "USD", fetchedAt: end)
    }
}

private struct ClaudeCostReport: Decodable {
    struct Bucket: Decodable { let results: [Result] }
    struct Result: Decodable {
        let amount: Decimal
        private enum CodingKeys: String, CodingKey { case amount }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decode(Decimal.self, forKey: .amount) {
                amount = value
            } else {
                let text = try container.decode(String.self, forKey: .amount)
                guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw DecodingError.dataCorruptedError(forKey: .amount, in: container, debugDescription: "Invalid decimal amount")
                }
                amount = value
            }
        }
    }
    let data: [Bucket]
    let has_more: Bool
    let next_page: String?
}

private func nextCursor(hasMore: Bool, nextPage: String?, seen: inout Set<String>) throws -> String? {
    guard hasMore else { return nil }
    guard let nextPage, !nextPage.isEmpty, seen.insert(nextPage).inserted else {
        throw ProviderError.invalidResponse
    }
    return nextPage
}
