import Foundation

/// Short, speech-friendly elapsed time. It deliberately never emits dates or timestamps.
public struct HumanTimeFormatter: Sendable {
    public init() {}

    public func string(since date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))

        switch seconds {
        case ..<45:
            return "just now"
        case ..<90:
            return "a minute ago"
        case ..<3_600:
            return quantity(rounded(seconds / 60), unit: "minute")
        case ..<5_400:
            return "an hour ago"
        case ..<86_400:
            return quantity(rounded(seconds / 3_600), unit: "hour")
        case ..<129_600:
            return "yesterday"
        case ..<604_800:
            return quantity(rounded(seconds / 86_400), unit: "day")
        case ..<1_209_600:
            return "a week ago"
        case ..<2_592_000:
            return quantity(rounded(seconds / 604_800), unit: "week")
        case ..<3_888_000:
            return "a month ago"
        case ..<31_536_000:
            return quantity(rounded(seconds / 2_592_000), unit: "month")
        case ..<47_304_000:
            return "a year ago"
        default:
            return quantity(rounded(seconds / 31_536_000), unit: "year")
        }
    }

    private func rounded(_ value: Double) -> Int {
        max(2, Int(value.rounded()))
    }

    private func quantity(_ value: Int, unit: String) -> String {
        let smallNumbers = [
            2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven",
            8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve"
        ]
        return "\(smallNumbers[value] ?? String(value)) \(unit)s ago"
    }
}
