import Foundation

/// A user-provided valuation, independent of the API's actual credit balance.
struct ElevenLabsUSDValuation: Codable, Equatable, Sendable {
    let credits: Decimal
    let usd: Decimal

    var isValid: Bool { !credits.isNaN && !usd.isNaN && credits > 0 && usd > 0 }

    func estimate(for amount: Decimal) -> Decimal? {
        guard isValid, !amount.isNaN, amount >= 0 else { return nil }
        let value = amount * usd / credits
        return value.isNaN ? nil : value
    }
}

enum CreditValuationError: LocalizedError {
    case invalidAmount
    var errorDescription: String? { "請輸入大於 0 的 credits 與 USD 金額。" }
}
