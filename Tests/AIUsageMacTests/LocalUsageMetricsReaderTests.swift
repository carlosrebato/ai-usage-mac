import AIUsageCore
import Foundation
import Testing
@testable import AIUsageMacServices

struct LocalUsageMetricsReaderTests {
    @Test(
        "Índice incremental real",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_LOCAL_METRICS_BENCHMARK"] == "1")
    )
    func indexesRealLogsOnceAndThenReadsZeroBytes() async throws {
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-usage-index-benchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: indexDirectory) }
        let reader = LocalUsageMetricsReader(
            indexURL: indexDirectory.appendingPathComponent("metrics.sqlite3"),
            refreshInterval: 0
        )
        let end = Date.now.addingTimeInterval(1)
        let start = end.addingTimeInterval(-60 * 24 * 60 * 60)
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            _ = await reader.weeklyTotals(for: .claude, periodStart: start, periodEnd: end)
            _ = await reader.weeklyTotals(for: .codex, periodStart: start, periodEnd: end)
        }
        let claudeFirst = await reader.diagnostics(for: .claude)
        let codexFirst = await reader.diagnostics(for: .codex)
        #expect((claudeFirst?.scannedBytes ?? 0) + (codexFirst?.scannedBytes ?? 0) > 0)

        let initialBytes = (claudeFirst?.scannedBytes ?? 0) + (codexFirst?.scannedBytes ?? 0)
        _ = await reader.weeklyTotals(for: .claude, periodStart: start, periodEnd: end)
        _ = await reader.weeklyTotals(for: .codex, periodStart: start, periodEnd: end)
        let incrementalBytes = (await reader.diagnostics(for: .claude)?.scannedBytes ?? 0)
            + (await reader.diagnostics(for: .codex)?.scannedBytes ?? 0)
        #expect(incrementalBytes < max(1_000_000, initialBytes / 100))
        print(
            "Cold local metrics index completed in \(elapsed); "
                + "initial bytes \(initialBytes), immediate incremental bytes \(incrementalBytes)"
        )
    }

    @Test func claudeAggregatesTokensAndEquivalentCostWithoutDoubleCountingMessages() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try writeLines([
            claudeLine(messageID: "message-1"),
            claudeLine(messageID: "message-1")
        ], to: file)

        let totals = await LocalUsageMetricsReader(homeDirectory: home).weeklyTotals(
            for: .claude,
            periodStart: date("2026-07-20T00:00:00Z"),
            periodEnd: date("2026-07-24T00:00:00Z")
        )

        #expect(totals?.inputTokens == 100)
        #expect(totals?.cachedInputTokens == 1_000)
        #expect(totals?.cacheWriteTokens == 200)
        #expect(totals?.outputTokens == 50)
        #expect(totals?.totalTokens == 1_350)
        #expect(abs((totals?.equivalentCostUSD ?? 0) - 0.0014) < 0.000_001)
        #expect(totals?.hasUnpricedModels == false)
    }

    @Test func claudeKeepsTheLargestFinalCounterForRepeatedMessageIDs() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try writeLines([
            claudeLine(messageID: "streamed", input: 100),
            claudeLine(messageID: "streamed", input: 200)
        ], to: file)

        let totals = await LocalUsageMetricsReader(homeDirectory: home).weeklyTotals(
            for: .claude,
            periodStart: date("2026-07-20T00:00:00Z"),
            periodEnd: date("2026-07-24T00:00:00Z")
        )
        #expect(totals?.totalTokens == 1_450)
        #expect(totals?.inputTokens == 200)
    }

    @Test func claudeLightweightParserSupportsTimestampAfterMessageAndIgnoresContentKeys() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try writeLines([
            #"{"message":{"model":"claude-sonnet-5","id":"real-message","type":"message","role":"assistant","content":[{"type":"text","text":"an id and timestamp inside content"}],"usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":200,"ephemeral_1h_input_tokens":0}}},"uuid":"fallback","timestamp":"2026-07-23T10:00:00Z","type":"assistant"}"#
        ], to: file)

        let totals = await LocalUsageMetricsReader(homeDirectory: home).weeklyTotals(
            for: .claude,
            periodStart: date("2026-07-20T00:00:00Z"),
            periodEnd: date("2026-07-24T00:00:00Z")
        )
        #expect(totals?.totalTokens == 1_350)
    }

    @Test func codexUsesCumulativeDeltasAndDoesNotDoubleCountReasoning() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".codex/sessions/2026/07/23", isDirectory: true)
            .appendingPathComponent("rollout.jsonl")
        try writeLines([
            #"{"timestamp":"2026-07-23T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            codexTokenLine(input: 100, cached: 40, output: 10, reasoning: 2, total: 110),
            codexTokenLine(input: 250, cached: 100, output: 30, reasoning: 8, total: 280)
        ], to: file)

        let totals = await LocalUsageMetricsReader(homeDirectory: home).weeklyTotals(
            for: .codex,
            periodStart: date("2026-07-20T00:00:00Z"),
            periodEnd: date("2026-07-24T00:00:00Z")
        )

        #expect(totals?.inputTokens == 150)
        #expect(totals?.cachedInputTokens == 100)
        #expect(totals?.outputTokens == 30)
        #expect(totals?.reasoningTokens == 8)
        #expect(totals?.totalTokens == 280)
        #expect(abs((totals?.equivalentCostUSD ?? 0) - 0.0017) < 0.000_001)
        #expect(totals?.hasUnpricedModels == false)
    }

    @Test func claudeOpusFiveUsesCurrentPublicPricing() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try writeLines([
            """
            {"timestamp":"2026-08-10T07:41:11Z","type":"assistant","message":{"id":"opus-5-message","model":"claude-opus-5","usage":{"input_tokens":1,"cache_read_input_tokens":69858,"cache_creation_input_tokens":860,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":860},"output_tokens":183}}}
            """
        ], to: file)

        let totals = await LocalUsageMetricsReader(homeDirectory: home).weeklyTotals(
            for: .claude,
            periodStart: date("2026-08-10T00:00:00Z"),
            periodEnd: date("2026-08-11T00:00:00Z")
        )

        #expect(totals?.totalTokens == 70_902)
        #expect(abs((totals?.equivalentCostUSD ?? 0) - 0.048109) < 0.000_001)
        #expect(totals?.hasUnpricedModels == false)
    }

    @Test func codexPreservesTotalsWhenTheImportedSessionHasNoBreakdown() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".codex/sessions/2026/08/10", isDirectory: true)
            .appendingPathComponent("rollout.jsonl")
        try writeLines([
            codexTokenLine(input: 0, cached: 0, output: 0, reasoning: 0, total: 97_347)
        ], to: file)

        let totals = await LocalUsageMetricsReader(homeDirectory: home).weeklyTotals(
            for: .codex,
            periodStart: date("2026-07-20T00:00:00Z"),
            periodEnd: date("2026-07-24T00:00:00Z")
        )

        #expect(totals?.totalTokens == 97_347)
        #expect(totals?.unclassifiedTokens == 97_347)
        #expect(totals?.equivalentCostUSD == nil)
        #expect(totals?.hasUnpricedModels == true)
    }

    @Test func reconstructsClaudeDailyTokensAndDeduplicatesRepeatedMessages() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try writeLines([
            claudeLine(messageID: "day-one", timestamp: "2026-07-22T10:00:00Z"),
            claudeLine(messageID: "day-one", timestamp: "2026-07-22T10:00:00Z"),
            claudeLine(messageID: "day-two", timestamp: "2026-07-23T10:00:00Z")
        ], to: file)

        let totals = await LocalUsageMetricsReader(homeDirectory: home).dailyTokenTotals(
            for: .claude,
            periodStart: date("2026-07-22T00:00:00Z"),
            periodEnd: date("2026-07-24T00:00:00Z")
        )

        #expect(totals[Calendar.current.startOfDay(for: date("2026-07-22T10:00:00Z"))] == 1_350)
        #expect(totals[Calendar.current.startOfDay(for: date("2026-07-23T10:00:00Z"))] == 1_350)
    }

    @Test func reconstructsCodexDailyTokensFromCumulativeDeltas() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".codex/sessions/2026/07/23", isDirectory: true)
            .appendingPathComponent("rollout.jsonl")
        try writeLines([
            codexTokenLine(
                input: 100,
                cached: 40,
                output: 10,
                reasoning: 2,
                total: 110,
                timestamp: "2026-07-22T10:01:00Z"
            ),
            codexTokenLine(
                input: 250,
                cached: 100,
                output: 30,
                reasoning: 8,
                total: 280,
                timestamp: "2026-07-23T10:01:00Z"
            )
        ], to: file)

        let totals = await LocalUsageMetricsReader(homeDirectory: home).dailyTokenTotals(
            for: .codex,
            periodStart: date("2026-07-22T00:00:00Z"),
            periodEnd: date("2026-07-24T00:00:00Z")
        )

        #expect(totals[Calendar.current.startOfDay(for: date("2026-07-22T10:00:00Z"))] == 110)
        #expect(totals[Calendar.current.startOfDay(for: date("2026-07-23T10:00:00Z"))] == 170)
    }

    @Test func unchangedLogsAreReusedAndAppendReadsOnlyNewBytes() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try writeLines([claudeLine(messageID: "first")], to: file)
        let reader = LocalUsageMetricsReader(homeDirectory: home, refreshInterval: 0)
        let start = date("2026-07-20T00:00:00Z")
        let end = date("2026-07-24T00:00:00Z")

        let first = await reader.weeklyTotals(for: .claude, periodStart: start, periodEnd: end)
        let initialDiagnostics = await reader.diagnostics(for: .claude)
        #expect(first?.totalTokens == 1_350)
        #expect(initialDiagnostics?.scannedFiles == 1)
        #expect(initialDiagnostics?.scannedBytes == Int64(try Data(contentsOf: file).count))

        _ = await reader.weeklyTotals(for: .claude, periodStart: start, periodEnd: end)
        let unchangedDiagnostics = await reader.diagnostics(for: .claude)
        #expect(unchangedDiagnostics == LocalUsageMetricsDiagnostics(
            scannedFiles: 0,
            scannedBytes: 0,
            reusedFiles: 1
        ))

        let appendedLine = claudeLine(messageID: "second") + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()

        let updated = await reader.weeklyTotals(for: .claude, periodStart: start, periodEnd: end)
        let appendDiagnostics = await reader.diagnostics(for: .claude)
        #expect(updated?.totalTokens == 2_700)
        #expect(appendDiagnostics?.scannedFiles == 1)
        #expect(appendDiagnostics?.scannedBytes == Int64(appendedLine.utf8.count))
    }

    @Test func truncatedLogRebuildsOnlyThatFileAndRemovesOldEvents() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try writeLines([
            claudeLine(messageID: "first"),
            claudeLine(messageID: "second")
        ], to: file)
        let reader = LocalUsageMetricsReader(homeDirectory: home, refreshInterval: 0)
        let start = date("2026-07-20T00:00:00Z")
        let end = date("2026-07-24T00:00:00Z")

        #expect(await reader.weeklyTotals(
            for: .claude,
            periodStart: start,
            periodEnd: end
        )?.totalTokens == 2_700)

        try writeLines([claudeLine(messageID: "replacement")], to: file)
        let rebuilt = await reader.weeklyTotals(for: .claude, periodStart: start, periodEnd: end)
        #expect(rebuilt?.totalTokens == 1_350)
        #expect(await reader.diagnostics(for: .claude)?.scannedFiles == 1)
    }

    @Test func repeatedPollingReusesMetricsUntilTheIndexRefreshes() async throws {
        let home = temporaryHome()
        let file = home
            .appendingPathComponent(".claude/projects/demo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try writeLines([claudeLine(messageID: "first")], to: file)
        let reader = LocalUsageMetricsReader(
            homeDirectory: home,
            refreshInterval: 0
        )
        let start = date("2026-07-20T00:00:00Z")
        let firstEnd = date("2026-07-24T00:00:00Z")
        let laterEnd = firstEnd.addingTimeInterval(2 * 60)

        _ = await reader.weeklyTotals(
            for: .claude,
            periodStart: start,
            periodEnd: firstEnd
        )
        _ = await reader.weeklyTotals(
            for: .claude,
            periodStart: start.addingTimeInterval(2 * 60),
            periodEnd: laterEnd
        )
        #expect(await reader.databaseQueryCount(for: .claude) == 1)

        _ = await reader.dailyTokenTotals(
            for: .claude,
            periodStart: start,
            periodEnd: firstEnd
        )
        _ = await reader.dailyTokenTotals(
            for: .claude,
            periodStart: start.addingTimeInterval(2 * 60),
            periodEnd: laterEnd
        )
        #expect(await reader.databaseQueryCount(for: .claude) == 2)

        let appendedLine = claudeLine(messageID: "second") + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()
        let updated = await reader.weeklyTotals(
            for: .claude,
            periodStart: start,
            periodEnd: laterEnd
        )
        #expect(updated?.totalTokens == 2_700)
        #expect(await reader.databaseQueryCount(for: .claude) == 3)
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeLines(_ lines: [String], to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n")
            .data(using: .utf8)?
            .write(to: file)
    }

    private func claudeLine(
        messageID: String,
        timestamp: String = "2026-07-23T10:00:00Z",
        input: Int = 100
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"assistant","message":{"id":"\(messageID)","model":"claude-sonnet-5","usage":{"input_tokens":\(input),"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":200,"ephemeral_1h_input_tokens":0},"output_tokens":50}}}
        """
    }

    private func codexTokenLine(
        input: Int,
        cached: Int,
        output: Int,
        reasoning: Int,
        total: Int,
        timestamp: String = "2026-07-23T10:01:00Z"
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(total)}}}}
        """
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
