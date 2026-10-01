import Foundation

struct ElevenLabsBalance: Sendable {
    let limit: Decimal
    let used: Decimal
    let resetsAt: Date?
    let tier: String
    let fetchedAt: Date

    var remaining: Decimal { max(0, limit - used) }
}

struct ElevenLabsProvider: Sendable {
    var client = BillingHTTPClient()
    var now: @Sendable () -> Date = { .now }

    func fetchBalance(apiKey: String) async throws -> ElevenLabsBalance {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let data = try await client.data(for: request)
        let subscription = try JSONDecoder().decode(Subscription.self, from: data)
        guard subscription.character_limit >= 0, subscription.character_count >= 0 else {
            throw ProviderError.invalidResponse
        }
        return ElevenLabsBalance(
            limit: Decimal(subscription.character_limit),
            used: Decimal(subscription.character_count),
            resetsAt: subscription.next_character_count_reset_unix.flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
            },
            tier: subscription.tier,
            fetchedAt: now()
        )
    }

    private struct Subscription: Decodable {
        let tier: String
        let character_count: Int
        let character_limit: Int
        let next_character_count_reset_unix: TimeInterval?
    }
}
