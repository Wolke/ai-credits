import XCTest
@testable import AICreditsApp

@MainActor
final class CreditProviderTests: XCTestCase {
    func testOpenAIFetchesAllPagesWithStableTimeRange() async throws {
        let fixture = HTTPFixture([
            .init(body: #"{"data":[{"results":[{"amount":{"value":1.25,"currency":"usd"}}]}],"has_more":true,"next_page":"second"}"#),
            .init(body: #"{"data":[{"results":[{"amount":{"value":2.50,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#)
        ])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = try await OpenAIProvider(client: fixture.makeClient(), now: { now }).fetchUsage(apiKey: "test-key", since: now.addingTimeInterval(-200 * 86_400))
        XCTAssertEqual(usage.cumulativeCost, Decimal(string: "3.75"))
        XCTAssertEqual(usage.currency, "USD")
        XCTAssertEqual(fixture.requests.count, 2)
        let queries = fixture.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems! }
        XCTAssertEqual(queries[0].first { $0.name == "end_time" }, queries[1].first { $0.name == "end_time" })
        XCTAssertEqual(queries[1].first { $0.name == "page" }?.value, "second")
        XCTAssertEqual(fixture.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(fixture.requests[0].cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testClaudeFetchesBeyondFirstWeekAndConvertsCents() async throws {
        let fixture = HTTPFixture([
            .init(body: #"{"data":[{"results":[{"amount":"123.45"}]}],"has_more":true,"next_page":"next"}"#),
            .init(body: #"{"data":[{"results":[{"amount":200}]}],"has_more":false}"#)
        ])
        let usage = try await ClaudeProvider(client: fixture.makeClient()).fetchUsage(apiKey: "test-key", since: .now.addingTimeInterval(-60 * 86_400))
        XCTAssertEqual(usage.cumulativeCost, Decimal(string: "3.2345"))
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[1].value(forHTTPHeaderField: "x-api-key"), "test-key")
        let queries = fixture.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems! }
        XCTAssertEqual(queries[0].first { $0.name == "ending_at" }, queries[1].first { $0.name == "ending_at" })
        XCTAssertEqual(queries[1].first { $0.name == "page" }?.value, "next")
    }

    func testOpenAIRetainsDailyCostsAcrossPagesForGrantPeriodAuditing() async throws {
        let fixture = HTTPFixture([
            .init(body: #"{"data":[{"start_time":1782720000,"end_time":1782806400,"results":[{"amount":{"value":1.25,"currency":"usd"}}]}],"has_more":true,"next_page":"next"}"#),
            .init(body: #"{"data":[{"start_time":1782806400,"end_time":1782892800,"results":[{"amount":{"value":2.50,"currency":"usd"}}]}],"has_more":false}"#)
        ])
        let usage = try await OpenAIProvider(client: fixture.makeClient()).fetchUsage(apiKey: "test", since: Date(timeIntervalSince1970: 1782720000))
        XCTAssertEqual(usage.costBuckets?.count, 2)
        XCTAssertEqual(usage.costBuckets?.first?.start, Date(timeIntervalSince1970: 1782720000))
        XCTAssertEqual(usage.costBuckets?.last?.end, Date(timeIntervalSince1970: 1782892800))
        XCTAssertEqual(usage.costBuckets?.reduce(Decimal.zero) { $0 + $1.cost }, usage.cumulativeCost)
        var data = AppData()
        CostSynchronizer.apply(usage, since: Date(timeIntervalSince1970: 1782720000), source: nil, to: &data)
        let restored = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(restored.costSyncStates?[.openAI]?.costBuckets, usage.costBuckets)
    }

    func testMissingDailyDatesDoNotPretendToProvideACompleteHistory() async throws {
        let fixture = HTTPFixture([
            .init(body: #"{"data":[{"results":[{"amount":{"value":10,"currency":"usd"}}]}],"has_more":false}"#)
        ])
        let usage = try await OpenAIProvider(client: fixture.makeClient()).fetchUsage(apiKey: "test", since: .now.addingTimeInterval(-86_400))
        XCTAssertEqual(usage.cumulativeCost, 10)
        XCTAssertNil(usage.costBuckets)
    }

    func testRejectsMissingOrRepeatedPaginationCursor() async {
        for replies in [
            [HTTPFixture.Reply(body: #"{"data":[],"has_more":true}"#)],
            [HTTPFixture.Reply(body: #"{"data":[],"has_more":true,"next_page":"loop"}"#),
             HTTPFixture.Reply(body: #"{"data":[],"has_more":true,"next_page":"loop"}"#)]
        ] {
            let fixture = HTTPFixture(replies)
            do {
                _ = try await OpenAIProvider(client: fixture.makeClient()).fetchUsage(apiKey: "test", since: .now)
                XCTFail("Incomplete or looping reports must not replace the current balance")
            } catch {
                XCTAssertTrue(error is ProviderError)
            }
        }
    }

    func testLaterPageFailureDoesNotReturnPartialUsage() async {
        let fixture = HTTPFixture([
            .init(body: #"{"data":[{"results":[{"amount":"100"}]}],"has_more":true,"next_page":"next"}"#),
            .init(status: 403, body: #"{"error":{"message":"Forbidden"}}"#)
        ])
        do {
            _ = try await ClaudeProvider(client: fixture.makeClient()).fetchUsage(apiKey: "test", since: .now)
            XCTFail("Partial totals are unsafe")
        } catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
    }

    func testRetriesTransientServerAndConnectionErrors() async throws {
        let fixture = HTTPFixture([
            .init(body: "", error: URLError(.networkConnectionLost)),
            .init(status: 503, body: "Unavailable"),
            .init(body: "OK")
        ])
        let data = try await fixture.makeClient().data(for: URLRequest(url: URL(string: "https://example.invalid")!))
        XCTAssertEqual(String(data: data, encoding: .utf8), "OK")
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testDoesNotRetryInvalidKeyAndBoundsServerRetries() async {
        for code in [401, 503] {
            let fixture = HTTPFixture(Array(repeating: .init(status: code, body: "{}"), count: 3))
            do {
                _ = try await fixture.makeClient().data(for: URLRequest(url: URL(string: "https://example.invalid")!))
                XCTFail("Expected HTTP error")
            } catch { XCTAssertTrue(error.localizedDescription.contains(String(code))) }
            XCTAssertEqual(fixture.requests.count, code == 401 ? 1 : 3)
        }
    }

    func testElevenLabsUsesSubscriptionBalanceAndResetTimestamp() async throws {
        let fixture = HTTPFixture([.init(body: #"{"tier":"creator","character_count":12500,"character_limit":100000,"next_character_count_reset_unix":1800000000}"#)])
        let balance = try await ElevenLabsProvider(client: fixture.makeClient()).fetchBalance(apiKey: "eleven-test")
        XCTAssertEqual(balance.remaining, 87_500)
        XCTAssertEqual(balance.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(fixture.requests.first?.url?.path, "/v1/user/subscription")
        XCTAssertEqual(fixture.requests.first?.value(forHTTPHeaderField: "xi-api-key"), "eleven-test")
    }

    func testElevenLabsHandlesOverageAndMissingResetWithoutInventingDate() async throws {
        for reset in ["", #", "next_character_count_reset_unix":null"#] {
            let fixture = HTTPFixture([.init(body: "{\"tier\":\"free\",\"character_count\":12000,\"character_limit\":10000\(reset)}")])
            let balance = try await ElevenLabsProvider(client: fixture.makeClient()).fetchBalance(apiKey: "test")
            XCTAssertEqual(balance.remaining, 0)
            XCTAssertNil(balance.resetsAt)
        }
    }
}
