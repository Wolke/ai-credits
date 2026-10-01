import XCTest
@testable import AICreditsApp

final class NotificationMilestoneTests: XCTestCase {
    func testMilestonesIncludeMissedBoundaryDays() {
        XCTAssertNil(NotificationMilestone.stage(forDaysRemaining: 31))
        XCTAssertEqual(NotificationMilestone.stage(forDaysRemaining: 29), 30)
        XCTAssertEqual(NotificationMilestone.stage(forDaysRemaining: 6), 7)
        XCTAssertEqual(NotificationMilestone.stage(forDaysRemaining: 1), 1)
        XCTAssertEqual(NotificationMilestone.stage(forDaysRemaining: 0), 0)
        XCTAssertNil(NotificationMilestone.stage(forDaysRemaining: -1))
    }
}
