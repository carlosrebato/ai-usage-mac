import Foundation

public struct UsageHistoryDay: Identifiable, Equatable, Codable, Sendable {
    public let date: Date
    public var claudePercent: Double?
    public var codexPercent: Double?
    public var claudeTokens: Int?
    public var codexTokens: Int?
    public var activity: Bool?

    public init(
        date: Date,
        claudePercent: Double? = nil,
        codexPercent: Double? = nil,
        claudeTokens: Int? = nil,
        codexTokens: Int? = nil,
        activity: Bool? = nil
    ) {
        self.date = date
        self.claudePercent = claudePercent
        self.codexPercent = codexPercent
        self.claudeTokens = claudeTokens
        self.codexTokens = codexTokens
        self.activity = activity
    }

    public var id: Date { date }

    public var hasUsage: Bool {
        activity == true
            || (claudePercent ?? 0) > 0
            || (codexPercent ?? 0) > 0
            || (claudeTokens ?? 0) > 0
            || (codexTokens ?? 0) > 0
    }

    public func percent(for provider: UsageProviderID) -> Double? {
        switch provider {
        case .claude: claudePercent
        case .codex: codexPercent
        }
    }

    public func tokens(for provider: UsageProviderID) -> Int? {
        switch provider {
        case .claude: claudeTokens
        case .codex: codexTokens
        }
    }
}

public struct UsageHistory: Equatable, Codable, Sendable {
    public var days: [UsageHistoryDay]

    public init(days: [UsageHistoryDay] = []) {
        self.days = days
    }

    public func lastSevenDays(relativeTo now: Date, calendar: Calendar = .current) -> [UsageHistoryDay] {
        let today = calendar.startOfDay(for: now)
        let indexed = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0) })
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return indexed[date] ?? UsageHistoryDay(date: date)
        }
    }

    public func currentStreak(relativeTo now: Date, calendar: Calendar = .current) -> Int {
        let indexed = Dictionary(uniqueKeysWithValues: days.map {
            (calendar.startOfDay(for: $0.date), $0.hasUsage)
        })
        var date = calendar.startOfDay(for: now)
        var count = 0
        while indexed[date] == true {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }
}

public struct UsageHistoryCache: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let base = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AIUsageAppGroup.identifier
        ) ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = base
            .appendingPathComponent("AIUsageMac", isDirectory: true)
            .appendingPathComponent("usage-history.json")
    }

    public func load() -> UsageHistory {
        guard
            let data = try? Data(contentsOf: fileURL),
            let history = try? JSONDecoder().decode(UsageHistory.self, from: data)
        else { return UsageHistory() }
        return history
    }

    public func recording(
        _ snapshots: [ProviderUsageSnapshot],
        at now: Date,
        calendar: Calendar = .current
    ) throws -> UsageHistory {
        var history = load()
        let day = calendar.startOfDay(for: now)
        var entry = history.days.first { calendar.isDate($0.date, inSameDayAs: day) }
            ?? UsageHistoryDay(date: day)

        for snapshot in snapshots where snapshot.source == .live {
            let value = snapshot.primaryDisplayWindow.usedPercent
            switch snapshot.id {
            case .claude:
                entry.claudePercent = max(entry.claudePercent ?? 0, value ?? 0)
            case .codex:
                entry.codexPercent = max(entry.codexPercent ?? 0, value ?? 0)
            }
        }

        history.days.removeAll { calendar.isDate($0.date, inSameDayAs: day) }
        history.days.append(entry)
        let cutoff = calendar.date(byAdding: .day, value: -60, to: day) ?? .distantPast
        history.days = history.days.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
        return history
    }

    public func applyingActivityDates(
        _ activityDates: Set<Date>,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar = .current
    ) throws -> UsageHistory {
        var history = load()
        let normalizedDates = Set(activityDates.map { calendar.startOfDay(for: $0) })

        for index in history.days.indices
        where history.days[index].date >= periodStart && history.days[index].date < periodEnd {
            let day = calendar.startOfDay(for: history.days[index].date)
            history.days[index].activity = normalizedDates.contains(day)
        }

        for day in normalizedDates where !history.days.contains(where: {
            calendar.isDate($0.date, inSameDayAs: day)
        }) {
            history.days.append(UsageHistoryDay(date: day, activity: true))
        }

        history.days.sort { $0.date < $1.date }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
        return history
    }

    public func applyingDailyTokens(
        _ totals: [UsageProviderID: [Date: Int]],
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar = .current
    ) throws -> UsageHistory {
        var history = load()
        let currentLedgerDay = calendar.startOfDay(
            for: periodEnd.addingTimeInterval(-1)
        )

        for provider in UsageProviderID.allCases {
            // A missing or empty scan is not proof that the user has no history.
            // Sandboxed access can be temporarily unavailable while a bookmark is
            // resolving, so preserve the last known series until real replacement
            // data is available.
            guard let providerTotals = totals[provider], !providerTotals.isEmpty else {
                continue
            }

            let normalized = Dictionary(
                providerTotals.map {
                    (calendar.startOfDay(for: $0.key), $0.value)
                },
                uniquingKeysWith: +
            )

            for (day, tokens) in normalized
            where periodStart <= day && day < periodEnd && tokens > 0 {
                let index = history.days.firstIndex {
                    calendar.isDate($0.date, inSameDayAs: day)
                }
                if let index {
                    let existing = history.days[index].tokens(for: provider)
                    // Closed days are immutable once recorded. The current day is
                    // monotonic, because an incremental scan may temporarily see
                    // fewer files than an earlier one.
                    guard existing == nil || day == currentLedgerDay else { continue }
                    let stableValue = max(existing ?? 0, tokens)
                    switch provider {
                    case .claude: history.days[index].claudeTokens = stableValue
                    case .codex: history.days[index].codexTokens = stableValue
                    }
                } else {
                    var entry = UsageHistoryDay(date: day)
                    switch provider {
                    case .claude: entry.claudeTokens = tokens
                    case .codex: entry.codexTokens = tokens
                    }
                    history.days.append(entry)
                }
            }
        }

        history.days.sort { $0.date < $1.date }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
        return history
    }
}
