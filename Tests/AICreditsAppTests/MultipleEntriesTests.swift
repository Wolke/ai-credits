import XCTest
@testable import AICreditsApp

@MainActor
final class MultipleEntriesTests: XCTestCase {
    func testThreeOpenAIEntriesRemainIndependent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = AppStore(persistence: PersistenceService(fileURL: directory.appending(path: "credits.json")), automaticallyRefresh: false)
        for index in 1...3 {
            var entry = CreditEntry()
            entry.platform = .openAI
            entry.name = "OpenAI Grant \(index)"
            entry.originalAmount = Decimal(index * 10)
            entry.remainingAmount = Decimal(index * 10)
            store.upsert(entry)
        }
        XCTAssertEqual(store.activeEntries.count, 3)
        XCTAssertEqual(Set(store.activeEntries.map(\.id)).count, 3)
        XCTAssertEqual(Set(store.activeEntries.map(\.name)), ["OpenAI Grant 1", "OpenAI Grant 2", "OpenAI Grant 3"])
    }
}
