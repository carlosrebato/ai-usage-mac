import AIUsageCore
import Foundation

public protocol LocalUsageMetricsReading: Sendable {
    func weeklyTotals(
        for provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) async -> WeeklyUsageTotals?

    func activityDates(
        for provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) async -> Set<Date>

    func dailyTokenTotals(
        for provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) async -> [Date: Int]
}

public extension LocalUsageMetricsReading {
    func activityDates(
        for _: UsageProviderID,
        periodStart _: Date,
        periodEnd _: Date
    ) async -> Set<Date> {
        []
    }

    func dailyTokenTotals(
        for _: UsageProviderID,
        periodStart _: Date,
        periodEnd _: Date
    ) async -> [Date: Int] {
        [:]
    }
}

public actor LocalUsageMetricsReader: LocalUsageMetricsReading {
    private struct WeeklyCache {
        let generation: Int
        let periodStart: Date
        let totals: WeeklyUsageTotals?
    }

    private struct DailyCache {
        let generation: Int
        let startDay: Date
        let endDay: Date
        let totals: [Date: Int]
    }

    private let claudeRoot: URL
    private let codexRoot: URL
    private let index: LocalUsageMetricsIndex?
    private let refreshInterval: TimeInterval
    private var lastRefresh: [UsageProviderID: Date] = [:]
    private var indexGeneration: [UsageProviderID: Int] = [:]
    private var weeklyCache: [UsageProviderID: WeeklyCache] = [:]
    private var dailyCache: [UsageProviderID: DailyCache] = [:]
    private var databaseQueryCounts: [UsageProviderID: Int] = [:]
    private var latestDiagnostics: [UsageProviderID: LocalUsageMetricsDiagnostics] = [:]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        indexURL: URL? = nil,
        refreshInterval: TimeInterval = 15 * 60
    ) {
        claudeRoot = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
        codexRoot = homeDirectory
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let bundleIdentifier = ProcessInfo.processInfo.environment["AI_USAGE_APP_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier
            ?? "com.example.aiusage"
        let resolvedIndexURL = indexURL ?? homeDirectory
            .appendingPathComponent("Library/Caches/\(bundleIdentifier)", isDirectory: true)
            .appendingPathComponent("usage-metrics-v1.sqlite3")
        index = try? LocalUsageMetricsIndex(databaseURL: resolvedIndexURL)
        self.refreshInterval = refreshInterval
    }

    public func weeklyTotals(
        for provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) async -> WeeklyUsageTotals? {
        refreshIndexIfNeeded(for: provider)
        let generation = indexGeneration[provider, default: 0]
        if let cached = weeklyCache[provider],
           cached.generation == generation,
           abs(cached.periodStart.timeIntervalSince(periodStart)) < 60 * 60 {
            return cached.totals
        }
        guard let events = try? index?.events(
            provider: provider,
            periodStart: periodStart,
            periodEnd: periodEnd
        ) else { return nil }
        databaseQueryCounts[provider, default: 0] += 1
        let result = totals(
            from: events,
            provider: provider,
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        weeklyCache[provider] = WeeklyCache(
            generation: generation,
            periodStart: periodStart,
            totals: result
        )
        return result
    }

    public func activityDates(
        for provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) async -> Set<Date> {
        Set(await dailyTokenTotals(
            for: provider,
            periodStart: periodStart,
            periodEnd: periodEnd
        ).keys)
    }

    public func dailyTokenTotals(
        for provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) async -> [Date: Int] {
        refreshIndexIfNeeded(for: provider)
        let generation = indexGeneration[provider, default: 0]
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: periodStart)
        let endDay = calendar.startOfDay(for: periodEnd)
        if let cached = dailyCache[provider],
           cached.generation == generation,
           cached.startDay == startDay,
           cached.endDay == endDay {
            return cached.totals
        }
        guard let totals = try? index?.dailyTokenTotals(
            provider: provider,
            periodStart: periodStart,
            periodEnd: periodEnd
        ) else { return [:] }
        databaseQueryCounts[provider, default: 0] += 1
        dailyCache[provider] = DailyCache(
            generation: generation,
            startDay: startDay,
            endDay: endDay,
            totals: totals
        )
        return totals
    }

    public func diagnostics(for provider: UsageProviderID) -> LocalUsageMetricsDiagnostics? {
        latestDiagnostics[provider]
    }

    func databaseQueryCount(for provider: UsageProviderID) -> Int {
        databaseQueryCounts[provider, default: 0]
    }

    private func totals(
        from events: [IndexedUsageEvent],
        provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) -> WeeklyUsageTotals? {
        var aggregate = TokenAggregate()
        for event in events {
            aggregate.input += event.input
            aggregate.cachedInput += event.cachedInput
            aggregate.cacheWrite += event.cacheWrite
            aggregate.output += event.output
            aggregate.reasoning += event.reasoning
            aggregate.unclassified += event.unclassified
            if event.unclassified > 0 { aggregate.hasUnpricedModels = true }

            let price = switch provider {
            case .claude: ModelPrice.claude(model: event.model, at: event.timestamp)
            case .codex: ModelPrice.codex(model: event.model, at: event.timestamp)
            }
            guard let price else {
                if event.input + event.cachedInput + event.cacheWrite + event.output > 0 {
                    aggregate.hasUnpricedModels = true
                }
                continue
            }

            aggregate.pricedTokens += event.input + event.cachedInput + event.cacheWrite + event.output
            let cacheWriteFallback = max(0, event.cacheWrite - event.cacheWrite5m - event.cacheWrite1h)
            aggregate.costUSD += price.cost(
                input: event.input,
                cachedInput: event.cachedInput,
                cacheWrite: event.cacheWrite5m + cacheWriteFallback,
                longCacheWrite: event.cacheWrite1h,
                output: event.output
            )
        }
        return aggregate.result(periodStart: periodStart, periodEnd: periodEnd)
    }

    private func refreshIndexIfNeeded(for provider: UsageProviderID) {
        guard let index else { return }
        if let lastRefresh = lastRefresh[provider],
           Date.now.timeIntervalSince(lastRefresh) < refreshInterval {
            return
        }
        let root = provider == .claude ? claudeRoot : codexRoot
        if let diagnostics = try? index.synchronize(provider: provider, root: root) {
            latestDiagnostics[provider] = diagnostics
            lastRefresh[provider] = .now
            if diagnostics.didChangeIndex || indexGeneration[provider] == nil {
                indexGeneration[provider, default: 0] += 1
            }
        }
    }
}

private struct TokenAggregate {
    var input = 0
    var cachedInput = 0
    var cacheWrite = 0
    var output = 0
    var reasoning = 0
    var unclassified = 0
    var pricedTokens = 0
    var costUSD = 0.0
    var hasUnpricedModels = false

    func result(periodStart: Date, periodEnd: Date) -> WeeklyUsageTotals? {
        let total = input + cachedInput + cacheWrite + output + unclassified
        guard total > 0 else { return nil }

        return WeeklyUsageTotals(
            inputTokens: input,
            cachedInputTokens: cachedInput,
            cacheWriteTokens: cacheWrite,
            outputTokens: output,
            reasoningTokens: reasoning,
            unclassifiedTokens: unclassified > 0 ? unclassified : nil,
            equivalentCostUSD: pricedTokens > 0 ? costUSD : nil,
            hasUnpricedModels: hasUnpricedModels,
            periodStart: periodStart,
            periodEnd: periodEnd
        )
    }
}

private struct ModelPrice {
    let input: Double
    let cachedInput: Double
    let cacheWrite: Double
    let longCacheWrite: Double
    let output: Double

    static func claude(model: String, at date: Date) -> ModelPrice? {
        let base: (input: Double, output: Double)
        switch model.lowercased() {
        case let value where value.hasPrefix("claude-sonnet-5"):
            let introductoryPriceEnds = DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2026,
                month: 9,
                day: 1
            ).date ?? .distantPast
            base = date < introductoryPriceEnds ? (2, 10) : (3, 15)
        case let value where value.hasPrefix("claude-opus-5"):
            base = (5, 25)
        case let value where value.hasPrefix("claude-opus-4-8")
            || value.hasPrefix("claude-opus-4-7")
            || value.hasPrefix("claude-opus-4-6")
            || value.hasPrefix("claude-opus-4-5"):
            base = (5, 25)
        case let value where value.hasPrefix("claude-fable-5")
            || value.hasPrefix("claude-mythos-5"):
            base = (10, 50)
        case let value where value.hasPrefix("claude-haiku-4-5"):
            base = (1, 5)
        case let value where value.hasPrefix("claude-sonnet-4-6")
            || value.hasPrefix("claude-sonnet-4-5"):
            base = (3, 15)
        default:
            return nil
        }

        return ModelPrice(
            input: base.input,
            cachedInput: base.input * 0.1,
            cacheWrite: base.input * 1.25,
            longCacheWrite: base.input * 2,
            output: base.output
        )
    }

    static func codex(model: String, at _: Date) -> ModelPrice? {
        switch model.lowercased() {
        case let value where value == "gpt-5.6" || value.hasPrefix("gpt-5.6-sol"):
            ModelPrice(input: 5, cachedInput: 0.5, cacheWrite: 6.25, longCacheWrite: 6.25, output: 30)
        case let value where value.hasPrefix("gpt-5.6-terra"):
            ModelPrice(input: 2.5, cachedInput: 0.25, cacheWrite: 3.125, longCacheWrite: 3.125, output: 15)
        case let value where value.hasPrefix("gpt-5.6-luna"):
            ModelPrice(input: 1, cachedInput: 0.1, cacheWrite: 1.25, longCacheWrite: 1.25, output: 6)
        default:
            nil
        }
    }

    func cost(
        input inputTokens: Int,
        cachedInput cachedInputTokens: Int,
        cacheWrite cacheWriteTokens: Int,
        longCacheWrite longCacheWriteTokens: Int,
        output outputTokens: Int
    ) -> Double {
        (
            Double(inputTokens) * input
                + Double(cachedInputTokens) * cachedInput
                + Double(cacheWriteTokens) * cacheWrite
                + Double(longCacheWriteTokens) * longCacheWrite
                + Double(outputTokens) * output
        ) / 1_000_000
    }
}
