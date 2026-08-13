import AIUsageCore
import Foundation
import Testing

struct UsageHistoryTests {
    @Test func recordsDailyPeaksAndCalculatesTheCurrentStreak() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-usage-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let cache = UsageHistoryCache(fileURL: fileURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = Date(timeIntervalSince1970: 1_786_406_400)
        let secondDay = calendar.date(byAdding: .day, value: 1, to: firstDay)!

        _ = try cache.recording(
            [snapshot(provider: .claude, percent: 42, at: firstDay)],
            at: firstDay,
            calendar: calendar
        )
        _ = try cache.recording(
            [snapshot(provider: .claude, percent: 31, at: firstDay)],
            at: firstDay.addingTimeInterval(3_600),
            calendar: calendar
        )
        let history = try cache.recording(
            [snapshot(provider: .codex, percent: 20, at: secondDay)],
            at: secondDay,
            calendar: calendar
        )

        #expect(history.days.count == 2)
        #expect(history.days[0].claudePercent == 42)
        #expect(history.days[1].codexPercent == 20)
        #expect(history.currentStreak(relativeTo: secondDay, calendar: calendar) == 2)
        #expect(history.lastSevenDays(relativeTo: secondDay, calendar: calendar).count == 7)

        let activityHistory = try cache.applyingActivityDates(
            [firstDay],
            periodStart: firstDay,
            periodEnd: secondDay.addingTimeInterval(24 * 60 * 60),
            calendar: calendar
        )
        #expect(activityHistory.days[0].activity == true)
        #expect(activityHistory.days[1].activity == false)
        #expect(activityHistory.currentStreak(relativeTo: secondDay, calendar: calendar) == 0)

        let tokenHistory = try cache.applyingDailyTokens(
            [
                .claude: [firstDay: 1_250],
                .codex: [firstDay: 800, secondDay: 2_400]
            ],
            periodStart: firstDay,
            periodEnd: secondDay.addingTimeInterval(24 * 60 * 60),
            calendar: calendar
        )
        #expect(tokenHistory.days[0].claudeTokens == 1_250)
        #expect(tokenHistory.days[0].codexTokens == 800)
        #expect(tokenHistory.days[1].claudeTokens == nil)
        #expect(tokenHistory.days[1].codexTokens == 2_400)

        let rebuiltHistory = try cache.applyingDailyTokens(
            [.codex: [secondDay: 900]],
            periodStart: firstDay,
            periodEnd: secondDay.addingTimeInterval(24 * 60 * 60),
            calendar: calendar
        )
        #expect(rebuiltHistory.days[0].claudeTokens == nil)
        #expect(rebuiltHistory.days[0].codexTokens == nil)
        #expect(rebuiltHistory.days[1].codexTokens == 900)
    }

    private func snapshot(
        provider: UsageProviderID,
        percent: Double,
        at date: Date
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: provider,
            session: UsageWindow(usedPercent: percent, resetsAt: nil),
            weekly: UsageWindow(usedPercent: percent, resetsAt: nil),
            observedAt: date,
            source: .live,
            message: nil
        )
    }
}
