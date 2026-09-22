import Foundation
import Testing
import AIUsageCore
@testable import AIUsageMacServices

struct CodexConnectorTests {
    @Test func appServerResponseClassifiesWeeklyWindowByDuration() throws {
        let data = Data(
            #"{"id":"2","result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":73,"windowDurationMins":10080,"resetsAt":3000}}}}"#.utf8
        )
        let snapshot = try CodexAppServerRateLimitsNormalizer.snapshot(
            from: data,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(snapshot.session.usedPercent == 42)
        #expect(snapshot.weekly.usedPercent == 73)
        #expect(snapshot.message?.contains("app-server") == true)
    }

    @Test(
        "Codex documented app-server fallback",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_CODEX_INTEGRATION_TEST"] == "1")
    )
    func readsTheLocalCodexSessionWithoutReadingAuthFile() async throws {
        let snapshot = try await CodexAppServerFallback().fetchSnapshot()
        #expect(snapshot.id == .codex)
        #expect(snapshot.highestPercent != nil)
    }
}
