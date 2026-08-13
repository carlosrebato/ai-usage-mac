import Foundation

public enum UsageResetFormatter {
    public static func string(until reset: Date?, relativeTo now: Date) -> String {
        guard let reset else { return "—" }

        let totalSeconds = max(0, Int(reset.timeIntervalSince(now)))
        let totalHours = totalSeconds / 3_600

        if totalHours >= 24 {
            let days = totalHours / 24
            let hours = totalHours % 24
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }

        let minutes = (totalSeconds % 3_600) / 60
        return totalHours > 0 ? "\(totalHours)h \(minutes)m" : "\(minutes)m"
    }
}
