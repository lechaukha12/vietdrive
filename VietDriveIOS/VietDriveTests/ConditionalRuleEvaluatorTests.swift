import XCTest
@testable import VietDrive

final class ConditionalRuleEvaluatorTests: XCTestCase {
    func testDayAndTimeWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Ho_Chi_Minh"))
        let mondayMorning = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 24, hour: 8, minute: 0
        )))
        let mondayNoon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 24, hour: 12, minute: 0
        )))
        XCTAssertTrue(ConditionalRuleEvaluator.isPotentiallyActive(
            "no @ (Mo-Fr 06:00-09:00)", at: mondayMorning, calendar: calendar
        ))
        XCTAssertFalse(ConditionalRuleEvaluator.isPotentiallyActive(
            "no @ (Mo-Fr 06:00-09:00)", at: mondayNoon, calendar: calendar
        ))
    }

    func testUnknownClauseStaysVisible() {
        XCTAssertTrue(ConditionalRuleEvaluator.isPotentiallyActive("permit holders only"))
    }
}
