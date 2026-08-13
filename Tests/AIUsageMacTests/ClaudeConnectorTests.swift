import Foundation
import Testing
import AIUsageCore
@testable import AIUsageMacServices

private struct EmptyClaudeCredentialLoader: ClaudeCredentialLoading {
    func loadCandidates() -> ClaudeCredentialLoad {
        ClaudeCredentialLoad(credentials: [], permissionRequired: false)
    }
}

private final class RecordingDesktopCredentialReader:
    ClaudeDesktopCredentialReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedLoadCount = 0

    var loadCount: Int {
        lock.withLock { storedLoadCount }
    }

    func cachedCredential(now _: Date) -> ClaudeCredential? {
        nil
    }

    func load(allowInteraction _: Bool, now _: Date) -> ClaudeDesktopCredentialStatus {
        lock.withLock { storedLoadCount += 1 }
        return .dataAccessRequired
    }
}

struct ClaudeConnectorTests {
    @Test func oauthUsageMapsSessionAndWeeklyWindows() throws {
        let data = Data(
            #"{"five_hour":{"utilization":25.5,"resets_at":"2026-07-22T12:00:00.000Z"},"seven_day":{"utilization":40,"resets_at":"2026-07-27T00:00:00Z"}}"#.utf8
        )

        let snapshot = try ClaudeUsageNormalizer.snapshot(
            from: data,
            plan: "Max 5x",
            observedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.id == .claude)
        #expect(snapshot.session.usedPercent == 25.5)
        #expect(snapshot.weekly.usedPercent == 40)
        #expect(snapshot.session.resetsAt != nil)
        #expect(snapshot.message == "Plan Max 5x")
        #expect(snapshot.source == .live)
    }

    @Test func oauthUsageClampsUnexpectedPercentages() throws {
        let data = Data(
            #"{"five_hour":{"utilization":-3},"seven_day":{"utilization":112}}"#.utf8
        )

        let snapshot = try ClaudeUsageNormalizer.snapshot(from: data, plan: nil, observedAt: .now)
        #expect(snapshot.session.usedPercent == 0)
        #expect(snapshot.weekly.usedPercent == 100)
    }

    @Test func credentialsAreParsedWithoutPersistingThem() {
        let data = Data(
            #"{"claudeAiOauth":{"accessToken":"secret-test-token","expiresAt":4102444800000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:profile","user:inference"]}}"#.utf8
        )

        let credential = ClaudeCredentialStore.parseCredentialData(data)
        #expect(credential?.accessToken == "secret-test-token")
        #expect(credential?.displayPlan == "Max 5x")
        #expect(credential?.scopes?.contains("user:profile") == true)
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
        #expect(snapshot?.source == .cached)
    }

    @Test func staleStatuslineIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("limits.json")
        try Data(#"{"sessionPercent":18,"weekPercent":37}"#.utf8).write(to: file)

        let oldDate = Date.now.addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        let snapshot = ClaudeStatuslineReader(fileURL: file, maximumAge: 600).readFresh(now: .now)
        #expect(snapshot == nil)
    }

    @Test func automaticRefreshStopsRetryingClaudeDesktopAfterPermissionFailure() async {
        let desktopReader = RecordingDesktopCredentialReader()
        let missingStatusline = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.json")
        let connector = ClaudeOAuthConnector(
            credentialStore: EmptyClaudeCredentialLoader(),
            desktopReader: desktopReader,
            statusline: ClaudeStatuslineReader(fileURL: missingStatusline)
        )

        for _ in 0..<2 {
            do {
                _ = try await connector.fetchSnapshot(allowInteraction: false)
                Issue.record("La actualización automática debería requerir una acción explícita")
            } catch let error as UsageConnectorError {
                guard case .permissionRequired = error else {
                    Issue.record("Se recibió un error inesperado: \(error.localizedDescription)")
                    return
                }
            } catch {
                Issue.record("Se recibió un error inesperado: \(error.localizedDescription)")
            }
        }

        #expect(desktopReader.loadCount == 1)
    }

    @Test(
        "Estado real del login local de Claude",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_CLAUDE_INTEGRATION_TEST"] == "1")
    )
    func probesTheLocalClaudeLogin() async {
        do {
            let snapshot = try await ClaudeOAuthConnector().fetchSnapshot(allowInteraction: true)
            #expect(snapshot.id == .claude)
            #expect(snapshot.highestPercent != nil)
        } catch let error as UsageConnectorError {
            let expected: Bool
            switch error {
            case .notAuthenticated, .rateLimited:
                expected = true
            default:
                expected = false
            }
            #expect(expected)
        } catch {
            Issue.record("Estado local no clasificado: \(error.localizedDescription)")
        }
    }
}
