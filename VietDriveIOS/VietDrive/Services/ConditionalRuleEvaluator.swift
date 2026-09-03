import Foundation

enum ConditionalRuleEvaluator {
    /// Each semicolon-separated schedule is an alternative. Within a schedule,
    /// days/dates constrain all its comma-separated time windows. Unrecognised
    /// syntax stays potentially active instead of hiding a restriction.
    static func isPotentiallyActive(
        _ conditional: String,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let text = conditional.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let schedules = text.replacingOccurrences(
            of: #"(:\d{2}\s*(?:[AaPp][Mm])?)\s*,\s*(?=(?:Mo|Tu|We|Th|Fr|Sa|Su)\b)"#,
            with: "$1;", options: .regularExpression
        ).split(separator: ";")
        guard !schedules.isEmpty else { return true }
        return schedules.contains { clause in
            let schedule = clause.split(separator: "@", maxSplits: 1).last.map(String.init) ?? ""
            return isActive(schedule, at: date, calendar: calendar)
        }
    }

    private static let dayNames = ["Su": 1, "Mo": 2, "Tu": 3, "We": 4, "Th": 5, "Fr": 6, "Sa": 7]
    private static let monthNames = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                                     "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
    private static let daysPattern = #"\b(Mo|Tu|We|Th|Fr|Sa|Su)(?:\s*-\s*(Mo|Tu|We|Th|Fr|Sa|Su))?\b"#
    private static let timesPattern = #"(\d{1,2}):(\d{2})\s*([AaPp][Mm])?\s*-\s*(\d{1,2}):(\d{2})\s*([AaPp][Mm])?"#
    private static let datesPattern = #"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})(?:\s*-\s*(?:(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+)?(\d{1,2}))?\b"#

    private static func isActive(_ input: String, at date: Date, calendar: Calendar) -> Bool {
        var text = input.replacingOccurrences(of: "đến", with: "-")
            .replacingOccurrences(of: "tới", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
            .replacingOccurrences(of: "từ ", with: "")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        if text.trimmingCharacters(in: CharacterSet(charactersIn: "() ")).lowercased() == "24/7" {
            return true
        }
        var weekdays: Set<Int> = []
        for groups in consume(daysPattern, from: &text) {
            guard let start = dayNames[groups[0]] else { return true }
            let end = dayNames[groups[1]] ?? start
            weekdays.formUnion(start <= end ? Array(start...end) : Array(start...7) + Array(1...end))
        }
        var dates: [(Int, Int)] = []
        for groups in consume(datesPattern, from: &text) {
            guard let month = monthNames[groups[0]], let day = Int(groups[1]) else { return true }
            let endMonth = monthNames[groups[2]] ?? month
            let endDay = Int(groups[3]) ?? day
            guard validDate(month: month, day: day), validDate(month: endMonth, day: endDay) else { return true }
            dates.append((month * 100 + day, endMonth * 100 + endDay))
        }
        var times: [(Int, Int)] = []
        for groups in consume(timesPattern, from: &text) {
            guard let start = minutes(hour: groups[0], minute: groups[1], suffix: groups[2]),
                  let end = minutes(hour: groups[3], minute: groups[4], suffix: groups[5]),
                  start < 24 * 60 else { return true }
            times.append((start, end))
        }
        // Unknown holidays, vehicle predicates or malformed ranges must not
        // become false merely because one recognised token matched.
        let remainder = text.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "(),"))).joined()
        guard remainder.isEmpty, !weekdays.isEmpty || !dates.isEmpty || !times.isEmpty else { return true }

        func matchesDay(_ day: Date) -> Bool {
            if !weekdays.isEmpty, !weekdays.contains(calendar.component(.weekday, from: day)) { return false }
            let value = calendar.component(.month, from: day) * 100 + calendar.component(.day, from: day)
            return dates.isEmpty || dates.contains { start, end in
                start <= end ? (start...end).contains(value) : value >= start || value <= end
            }
        }
        if times.isEmpty { return matchesDay(date) }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return times.contains { start, end in
            if start <= end { return minute >= start && minute <= end && matchesDay(date) }
            if minute >= start { return matchesDay(date) }
            guard minute <= end, let previousDay = calendar.date(byAdding: .day, value: -1, to: date) else { return false }
            return matchesDay(previousDay)
        }
    }

    private static func consume(_ pattern: String, from text: inout String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let values = regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
        text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return values
    }

    private static func minutes(hour: String, minute: String, suffix: String) -> Int? {
        guard var hour = Int(hour), let minute = Int(minute), minute < 60 else { return nil }
        if !suffix.isEmpty {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (suffix.uppercased() == "PM" ? 12 : 0)
        }
        guard hour < 24 || (hour == 24 && minute == 0) else { return nil }
        return hour * 60 + minute
    }

    private static func validDate(month: Int, day: Int) -> Bool {
        let days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[month - 1]).contains(day)
    }
}
