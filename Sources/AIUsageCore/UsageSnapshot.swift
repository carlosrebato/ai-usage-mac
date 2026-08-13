import Foundation

public enum UsageProviderID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    public var symbolName: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

public enum UsageSource: String, Codable, Sendable {
    case live
    case cached
    case mock
    case unavailable
}

public struct UsageFreshness: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case live
        case cached
    }

    public let kind: Kind
    public let date: Date

    public init(snapshots: [ProviderUsageSnapshot], now: Date) {
        let available = snapshots.filter {
            $0.highestPercent != nil && $0.source != .unavailable
        }
        let cached = available.filter { $0.source == .cached }
        let relevant = cached.isEmpty ? available : cached
        let observedAt = relevant.map(\.observedAt).min() ?? now

        kind = cached.isEmpty ? .live : .cached
        date = min(observedAt, now)
    }
}

public enum UsageSeverity: Int, Comparable, Codable, Sendable {
    case normal
    case warning
    case critical
    case unavailable

    public static func < (lhs: UsageSeverity, rhs: UsageSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func forPercent(_ value: Double?) -> UsageSeverity {
        guard let value else { return .unavailable }
        if value >= 85 { return .critical }
        if value >= 70 { return .warning }
        return .normal
    }
}

public struct UsageWindow: Equatable, Codable, Sendable {
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(usedPercent: Double?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var normalizedPercent: Double {
        min(max(usedPercent ?? 0, 0), 100)
    }
}

public struct WeeklyUsageTotals: Equatable, Codable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let unclassifiedTokens: Int?
    public let equivalentCostUSD: Double?
    public let hasUnpricedModels: Bool
    public let periodStart: Date
    public let periodEnd: Date

    public init(
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        unclassifiedTokens: Int? = nil,
        equivalentCostUSD: Double?,
        hasUnpricedModels: Bool,
        periodStart: Date,
        periodEnd: Date
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.unclassifiedTokens = unclassifiedTokens
        self.equivalentCostUSD = equivalentCostUSD
        self.hasUnpricedModels = hasUnpricedModels
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }

    public var totalTokens: Int {
        inputTokens + cachedInputTokens + cacheWriteTokens + outputTokens
            + (unclassifiedTokens ?? 0)
    }
}

public struct ProviderUsageSnapshot: Identifiable, Equatable, Codable, Sendable {
    public let id: UsageProviderID
    public let session: UsageWindow
    public let weekly: UsageWindow
    public let observedAt: Date
    public let source: UsageSource
    public let message: String?
    public let weeklyTotals: WeeklyUsageTotals?

    public init(
        id: UsageProviderID,
        session: UsageWindow,
        weekly: UsageWindow,
        observedAt: Date,
        source: UsageSource,
        message: String?,
        weeklyTotals: WeeklyUsageTotals? = nil
    ) {
        self.id = id
        self.session = session
        self.weekly = weekly
        self.observedAt = observedAt
        self.source = source
        self.message = message
        self.weeklyTotals = weeklyTotals
    }

    public var highestPercent: Double? {
        [session.usedPercent, weekly.usedPercent].compactMap { $0 }.max()
    }

    public var primaryDisplayWindow: UsageWindow {
        if id == .codex, session.usedPercent == nil, weekly.usedPercent != nil {
            return weekly
        }
        return session
    }

    public var severity: UsageSeverity {
        guard source != .unavailable else { return .unavailable }
        return UsageSeverity.forPercent(highestPercent)
    }

    public func isStale(at now: Date, after interval: TimeInterval = 10 * 60) -> Bool {
        now.timeIntervalSince(observedAt) > interval
    }
}
