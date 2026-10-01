import XCTest
import Security
@testable import AICreditsApp

@MainActor
final class CredentialInteractionTests: XCTestCase {
    func testSavingAndTestingDoesNotRequestOldKeyOrRereadSavedKeyInteractively() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = HTTPFixture([
            .init(body: #"{"tier":"free","character_count":1,"character_limit":100}"#),
            .init(body: #"{"tier":"free","character_count":2,"character_limit":100}"#)
        ])
        let credentials = TrackingCredentials()
        let store = AppStore(persistence: PersistenceService(fileURL: directory.appending(path: "credits.json")),
            keychain: credentials, client: fixture.makeClient(), automaticallyRefresh: false)
        try store.setAPIKey("saved-key", for: .elevenLabs)
        XCTAssertEqual(credentials.reads, [false])
        await store.refresh(platform: .elevenLabs)
        XCTAssertEqual(credentials.reads, [false], "The immediate test should reuse the successfully saved value")
        XCTAssertEqual(store.status(for: .elevenLabs).state, .success)
        await store.refresh(platform: .elevenLabs)
        XCTAssertEqual(credentials.reads, [false, true], "Later refreshes must read Keychain again")
    }

    func testFailedSaveNeverUsesUnsavedValueForAPI() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = HTTPFixture([])
        let credentials = TrackingCredentials(failWrite: true)
        let store = AppStore(persistence: PersistenceService(fileURL: directory.appending(path: "credits.json")),
            keychain: credentials, client: fixture.makeClient(), automaticallyRefresh: false)
        XCTAssertThrowsError(try store.setAPIKey("not-saved", for: .elevenLabs))
        await store.refresh(platform: .elevenLabs)
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(store.status(for: .elevenLabs).state, .failed)
    }

    func testClearingKeyRemovesPendingTestValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = HTTPFixture([])
        let credentials = TrackingCredentials()
        let store = AppStore(persistence: PersistenceService(fileURL: directory.appending(path: "credits.json")),
            keychain: credentials, client: fixture.makeClient(), automaticallyRefresh: false)
        try store.setAPIKey("saved-key", for: .elevenLabs)
        try store.setAPIKey("", for: .elevenLabs)
        await store.refresh(platform: .elevenLabs)
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(store.status(for: .elevenLabs).state, .notConfigured)
    }
}

private final class TrackingCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    private var value: String?
    private var saved = false
    let failWrite: Bool
    init(failWrite: Bool = false) { self.failWrite = failWrite }
    var reads: [Bool] { lock.withLock { recorded } }
    func get(for platform: CreditPlatform, allowInteraction: Bool) throws -> String? {
        try lock.withLock {
            recorded.append(allowInteraction)
            guard saved else { throw KeychainError.status(errSecInteractionNotAllowed) }
            return value
        }
    }
    func set(_ value: String, for platform: CreditPlatform) throws {
        try lock.withLock {
            guard !failWrite else { throw KeychainError.status(errSecUserCanceled) }
            self.value = value
            saved = true
        }
    }
    func delete(for platform: CreditPlatform) throws {
        lock.withLock { value = nil; saved = true }
    }
}
