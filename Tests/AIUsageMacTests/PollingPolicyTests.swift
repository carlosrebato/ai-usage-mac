import Foundation
import Testing
@testable import AIUsageCore

struct PollingPolicyTests {
    @Test func pollingAcceleratesNearTheLimit() {
        #expect(PollingPolicy.interval(for: .normal, consecutiveFailures: 0) == .seconds(120))
        #expect(PollingPolicy.interval(for: .warning, consecutiveFailures: 0) == .seconds(60))
        #expect(PollingPolicy.interval(for: .critical, consecutiveFailures: 0) == .seconds(30))
    }

    @Test func failuresUseBoundedExponentialBackoff() {
        #expect(PollingPolicy.interval(for: .normal, consecutiveFailures: 1) == .seconds(30))
        #expect(PollingPolicy.interval(for: .normal, consecutiveFailures: 2) == .seconds(60))
        #expect(PollingPolicy.interval(for: .normal, consecutiveFailures: 8) == .seconds(600))
    }
}
