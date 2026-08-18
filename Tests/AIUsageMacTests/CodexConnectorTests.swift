import Foundation
import Testing
import AIUsageCore
@testable import AIUsageMacServices

struct CodexConnectorTests {
    @Test func parsesTheReadOnlyLocalCodexCredential() throws {
        let data = Data(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"test-token","account_id":"account-123","refresh_token":"unused"}}"#.utf8
        )

        let credential = try CodexCredentialStore.parse(data)

        #expect(credential.accessToken == "test-token")
        #expect(credential.accountID == "account-123")
    }

    @Test func rejectsAnAuthFileWithoutAChatGPTSession() {
        let data = Data(#"{"auth_mode":"apikey"}"#.utf8)

        #expect(throws: UsageConnectorError.self) {
            try CodexCredentialStore.parse(data)
        }
    }

    @Test func currentWeeklyOnlyResponseIsClassifiedByDuration() throws {
        let data = Data(
            #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":57,"limit_window_seconds":604800,"reset_at":1787212071},"secondary_window":null}}"#.utf8
        )

        let snapshot = try CodexRateLimitsNormalizer.snapshot(
            from: data,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.session.usedPercent == nil)
        #expect(snapshot.weekly.usedPercent == 57)
        #expect(snapshot.weekly.resetsAt == Date(timeIntervalSince1970: 1787212071))
        #expect(snapshot.source == .live)
        #expect(snapshot.message == "Plan Plus")
    }

    @Test func sessionAndWeeklyResponseIsClassifiedByDuration() throws {
        let data = Data(
            #"{"plan_type":"team","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_at":2000},"secondary_window":{"used_percent":73,"limit_window_seconds":604800,"reset_at":3000}}}"#.utf8
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
            #"{"rate_limit":{"primary_window":{"used_percent":108,"limit_window_seconds":18000},"secondary_window":{"used_percent":-4,"limit_window_seconds":604800}}}"#.utf8
        )

        let snapshot = try CodexRateLimitsNormalizer.snapshot(from: data, observedAt: .now)
        #expect(snapshot.session.usedPercent == 100)
        #expect(snapshot.weekly.usedPercent == 0)
    }

    @Test(
        "Codex HTTP usage real",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_CODEX_INTEGRATION_TEST"] == "1")
    )
    func readsTheLocalCodexSession() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let connector = CodexAppServerConnector(
            credentialStore: CodexCredentialStore(codexRoot: root)
        )
        let snapshot = try await connector.fetchSnapshot()
        #expect(snapshot.id == .codex)
        #expect(snapshot.highestPercent != nil)
        #expect(snapshot.source == .live)
    }
}
