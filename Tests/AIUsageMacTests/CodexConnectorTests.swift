import Foundation
import Testing
import AIUsageCore
@testable import AIUsageMacServices

struct CodexConnectorTests {
    @Test func waitsForInitializationBeforeRequestingRateLimits() async throws {
        let connector = CodexAppServerConnector(
            executableURL: try orderedResponseExecutable(),
            timeout: .seconds(2)
        )

        let snapshot = try await connector.fetchSnapshot()

        #expect(snapshot.session.usedPercent == nil)
        #expect(snapshot.weekly.usedPercent == 35)
    }

    @Test func appServerIsTerminatedWhenItExceedsTheDeadline() async throws {
        let executable = try slowExecutable()
        let connector = CodexAppServerConnector(
            executableURL: executable,
            timeout: .milliseconds(50)
        )

        await #expect(throws: UsageConnectorError.timedOut) {
            try await connector.fetchSnapshot()
        }
    }

    @Test func cancellingTheRequestTerminatesTheAppServer() async throws {
        let connector = CodexAppServerConnector(
            executableURL: try slowExecutable(),
            timeout: .seconds(5)
        )
        let task = Task { try await connector.fetchSnapshot() }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func currentWeeklyOnlyResponseIsClassifiedByDuration() throws {
        let data = Data(
            #"{"id":"2","result":{"rateLimits":{"primary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1785274246},"secondary":null,"planType":"plus"}}}"#.utf8
        )

        let snapshot = try CodexRateLimitsNormalizer.snapshot(
            from: data,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.session.usedPercent == nil)
        #expect(snapshot.weekly.usedPercent == 2)
        #expect(snapshot.weekly.resetsAt == Date(timeIntervalSince1970: 1785274246))
        #expect(snapshot.source == .live)
        #expect(snapshot.message == "Plan Plus")
    }

    @Test func legacySessionAndWeeklyResponseRemainsSupported() throws {
        let data = Data(
            #"{"id":"2","result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":73,"windowDurationMins":10080,"resetsAt":3000},"planType":"team"}}}"#.utf8
        )

        let snapshot = try CodexRateLimitsNormalizer.snapshot(
            from: data,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.session.usedPercent == 42)
        #expect(snapshot.weekly.usedPercent == 73)
        #expect(snapshot.severity == .warning)
    }

    @Test func percentagesAreClamped() throws {
        let data = Data(
            #"{"id":"2","result":{"rateLimits":{"primary":{"usedPercent":108,"windowDurationMins":300},"secondary":{"usedPercent":-4,"windowDurationMins":10080}}}}"#.utf8
        )

        let snapshot = try CodexRateLimitsNormalizer.snapshot(from: data, observedAt: .now)
        #expect(snapshot.session.usedPercent == 100)
        #expect(snapshot.weekly.usedPercent == 0)
    }

    @Test(
        "Codex app-server real",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_CODEX_INTEGRATION_TEST"] == "1")
    )
    func readsTheLocalCodexSession() async throws {
        let snapshot = try await CodexAppServerConnector().fetchSnapshot()
        #expect(snapshot.id == .codex)
        #expect(snapshot.highestPercent != nil)
        #expect(snapshot.source == .live)
    }

    private func slowExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("slow-codex")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func orderedResponseExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("ordered-codex")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\\n' '{"id":"1","result":{"userAgent":"test"}}'
        IFS= read -r rate_limits
        case "$rate_limits" in
          *rateLimits*read*)
            printf '%s\\n' '{"id":"2","result":{"rateLimits":{"primary":{"usedPercent":35,"windowDurationMins":10080},"secondary":null}}}'
            ;;
          *)
            exit 1
            ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
