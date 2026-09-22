import Foundation
import Testing
import AIUsageCore
@testable import AIUsageMacServices

private actor EventuallyReadyUsageConnector: UsageConnector {
    nonisolated let providerID = UsageProviderID.claude
    private var missingResponses: Int

    init(missingResponses: Int) {
        self.missingResponses = missingResponses
    }

    func fetchSnapshot(allowInteraction _: Bool) async throws -> ProviderUsageSnapshot {
        if missingResponses > 0 {
            missingResponses -= 1
            throw UsageConnectorError.missingUsageWindows
        }
        return ProviderUsageSnapshot(
            id: .claude,
            session: UsageWindow(usedPercent: 17, resetsAt: nil),
            weekly: UsageWindow(usedPercent: 29, resetsAt: nil),
            observedAt: .now,
            source: .live,
            message: "Direct"
        )
    }
}

struct ClaudeConnectorTests {
    @Test func missingWindowsDoNotOpenTheCircuitWhileOAuthPropagates() async throws {
        let connector = ResilientUsageConnector(
            direct: EventuallyReadyUsageConnector(missingResponses: 3),
            localFallback: nil
        )

        for _ in 0..<3 {
            await #expect(throws: UsageConnectorError.missingUsageWindows) {
                try await connector.fetchSnapshot(allowInteraction: false)
            }
        }
        let snapshot = try await connector.fetchSnapshot(allowInteraction: false)

        #expect(snapshot.session.usedPercent == 17)
    }

    @Test func recentStatuslineCanActAsFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("limits.json")
        let observedAt = Date.now
        let payload = #"{"sessionPercent":18,"weekPercent":37,"resetAt":"2026-07-22T12:00:00Z","weekResetAt":"2026-07-27T00:00:00Z","lastUpdated":"2026-07-22T08:00:00Z"}"#
        try Data(payload.utf8).write(to: file)

        let snapshot = ClaudeStatuslineReader(fileURL: file).readFresh(now: observedAt)
        #expect(snapshot?.session.usedPercent == 18)
        #expect(snapshot?.weekly.usedPercent == 37)
        #expect(snapshot?.source == .live)
    }

    @Test func futureStatuslineTimestampIsClampedToRefreshTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("limits.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(6 * 60 * 60))
        let payload = #"{"sessionPercent":18,"weekPercent":37,"lastUpdated":"\#(future)"}"#
        try Data(payload.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        let snapshot = ClaudeStatuslineReader(fileURL: file).readFresh(now: now)

        #expect(snapshot?.observedAt == now)
        #expect(snapshot?.source == .live)
    }

    @Test func staleStatuslineIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("limits.json")
        try Data(#"{"sessionPercent":18,"weekPercent":37}"#.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-3600)],
            ofItemAtPath: file.path
        )

        #expect(ClaudeStatuslineReader(fileURL: file, maximumAge: 600).readFresh(now: .now) == nil)
    }
}
