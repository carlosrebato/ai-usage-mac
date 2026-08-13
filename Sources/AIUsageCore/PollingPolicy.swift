import Foundation

public enum PollingPolicy {
    public static func interval(for severity: UsageSeverity, consecutiveFailures: Int) -> Duration {
        if consecutiveFailures > 0 {
            let seconds = min(600, 30 * (1 << min(consecutiveFailures - 1, 5)))
            return .seconds(seconds)
        }

        switch severity {
        case .normal: return .seconds(120)
        case .warning: return .seconds(60)
        case .critical: return .seconds(30)
        case .unavailable: return .seconds(30)
        }
    }
}
