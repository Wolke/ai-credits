import XCTest
@testable import AICreditsApp

final class PersistenceTests: XCTestCase {
    func testRoundTripDoesNotContainCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "credits.json")
        let service = PersistenceService(fileURL: url)
        var data = AppData()
        var entry = CreditEntry()
        entry.name = "Promo"
        entry.originalAmount = 10
        entry.remainingAmount = 8
        data.entries = [entry]

        try service.save(data)
        let loaded = try XCTUnwrap(service.load().entries.first)
        XCTAssertEqual(loaded.id, entry.id)
        XCTAssertEqual(loaded.name, "Promo")
        XCTAssertEqual(loaded.originalAmount, 10)
        XCTAssertEqual(loaded.remainingAmount, 8)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).lowercased().contains("api_key"))
    }
}
