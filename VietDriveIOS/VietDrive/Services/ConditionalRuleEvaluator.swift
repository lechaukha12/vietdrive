import Foundation

enum ConditionalRuleEvaluator {
    /// Evaluates the common OSM `*:conditional` day/time form. Unknown clauses
    /// remain active so VietDrive never silently hides a potentially legal rule.
    static func isPotentiallyActive(
        _ conditional: String,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let text = conditional.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        if let allowedWeekdays = weekdays(in: text),
           !allowedWeekdays.contains(calendar.component(.weekday, from: date)) {
            return false
        }

        guard let range = timeRange(in: text) else { return true }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if range.start <= range.end {
            return minute >= range.start && minute <= range.end
        }
        return minute >= range.start || minute <= range.end
    }

    private static func timeRange(in text: String) -> (start: Int, end: Int)? {
        // Normalize Vietnamese and English separators to a simple dash,
        // strip AM/PM suffixes, and collapse whitespace so the regex can
        // match forms like "6:00AM đến 22:00PM" or "08:00 to 17:00".
        let normalized = text
            .replacingOccurrences(of: "đến", with: "-")
            .replacingOccurrences(of: "tới", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
            .replacingOccurrences(of: "từ ", with: "")
            .replacingOccurrences(of: "AM", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "PM", with: "", options: .caseInsensitive)
        guard let match = normalized.firstMatch(of: /(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})/) else {
            return nil
        }
        guard let startHour = Int(match.1), let startMinute = Int(match.2),
              let endHour = Int(match.3), let endMinute = Int(match.4),
              startHour < 24, endHour < 24, startMinute < 60, endMinute < 60 else {
            return nil
        }
        return (startHour * 60 + startMinute, endHour * 60 + endMinute)
    }

    private static func weekdays(in text: String) -> Set<Int>? {
        let mapping = ["Su": 1, "Mo": 2, "Tu": 3, "We": 4, "Th": 5, "Fr": 6, "Sa": 7]
        guard let match = text.firstMatch(of: /\b(Mo|Tu|We|Th|Fr|Sa|Su)(?:-(Mo|Tu|We|Th|Fr|Sa|Su))?\b/),
              let start = mapping[String(match.1)] else { return nil }
        guard let endToken = match.2, let end = mapping[String(endToken)] else {
            return [start]
        }
        if start <= end { return Set(start...end) }
        return Set(Array(start...7) + Array(1...end))
    }
}

