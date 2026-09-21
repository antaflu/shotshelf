import Foundation

/// A run of screenshots from roughly the same time, with a human label.
struct ShelfGroup: Identifiable {
    var title: String
    var items: [ShelfItem]

    var id: String { title }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter
    }()

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    /// Counts in whole days, so a screenshot from last night is "Yesterday"
    /// rather than "18 hours ago".
    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0

        switch days {
        case ..<0: return "Today"        // a clock skew shouldn't read as "in 2 days"
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "Earlier this week"
        case 7...13: return "Last week"
        case 14...20: return "2 weeks ago"
        case 21...27: return "3 weeks ago"
        default:
            let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
            return (sameYear ? monthFormatter : monthYearFormatter).string(from: date)
        }
    }
}
