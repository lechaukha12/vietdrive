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

    func testAlternativeSchedulesAndClockFormats() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Ho_Chi_Minh"))
        let cases: [(String, Int, Int, Int, Bool)] = [
            ("no @ (Fr 19:00-23:59; Sa-Su 00:00-23:59)", 5, 10, 0, true),
            ("no @ (Fr 19:00-23:59; Sa-Su 00:00-23:59)", 6, 10, 0, true),
            ("no @ (Fr 19:00-23:59; Sa-Su 00:00-23:59)", 4, 18, 0, false),
            ("no @ (Fr 19:00-23:59; Sa-Su 00:00-23:59)", 7, 10, 0, false),
            ("no @ (Mo-Fr 06:00-09:00,16:00-20:00)", 7, 17, 0, true),
            ("no @ (Mo-Fr 06:00-09:00,16:00-20:00)", 7, 12, 0, false),
            ("no @ (Mo,We,Fr 06:00-09:00)", 9, 8, 0, true),
            ("no @ (Mo,We,Fr 06:00-09:00)", 8, 8, 0, false),
            ("no @ (Mo 06:00-09:00, Fr 16:00-20:00)", 4, 17, 0, true),
            ("no @ (Mo 06:00-09:00, Fr 16:00-20:00)", 4, 8, 0, false),
            ("no @ (Fr 22:00-02:00)", 5, 1, 0, true),
            ("no @ (Fr 22:00-02:00)", 4, 1, 0, false),
            ("no @ (Fr 22:00-02:00)", 5, 23, 0, false),
            ("no @ (01:00PM đến 03:00PM)", 3, 14, 0, true),
            ("no @ (01:00PM đến 03:00PM)", 3, 2, 0, false),
            ("no @ (12:00AM-01:00AM)", 3, 0, 30, true),
            ("no @ (12:00PM-01:00PM)", 3, 12, 30, true),
            ("no @ (22:00-24:00)", 3, 23, 59, true),
            ("no @ (Mo-Fr sunrise-sunset)", 5, 12, 0, true),
            ("no @ (Mo-Fr 25:00-26:00)", 5, 12, 0, true)
        ]
        for (condition, day, hour, minute, expected) in cases {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 9, day: day, hour: hour, minute: minute
            )))
            XCTAssertEqual(ConditionalRuleEvaluator.isPotentiallyActive(condition, at: date, calendar: calendar),
                           expected, "\(condition) · Sep \(day) \(hour):\(minute)")
        }
    }

    func testDatedExceptionsDoNotHideWeekendSchedulesOrApplyAllYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Ho_Chi_Minh"))
        let condition = "no @ (Feb 16 19:30-23:59; Feb 17 00:01-02:00; Fr 19:00-23:59; Sa-Su 00:00-23:59)"
        for (month, day, hour, expected) in [(2, 16, 20, true), (2, 17, 1, true),
                                            (9, 5, 10, true), (9, 3, 20, false)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
            XCTAssertEqual(ConditionalRuleEvaluator.isPotentiallyActive(condition, at: date, calendar: calendar), expected)
        }
        let december = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 10)))
        XCTAssertTrue(ConditionalRuleEvaluator.isPotentiallyActive("no @ (Dec 20-Jan 05 08:00-12:00)", at: december, calendar: calendar))
        XCTAssertFalse(ConditionalRuleEvaluator.isPotentiallyActive("no @ (May 30-Jun 30 05:00-13:30)", at: december, calendar: calendar))
    }
}
