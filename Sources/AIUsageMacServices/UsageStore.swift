import AIUsageCore
import Foundation
import WidgetKit

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var snapshots: [ProviderUsageSnapshot]
    @Published public private(set) var connectionStatuses: [ProviderConnectionStatus]
    @Published public private(set) var history: UsageHistory
    @Published public private(set) var isRefreshing = false
    private let connectors: [any UsageConnector]
    private let cache: UsageSnapshotCache
    private let historyCache: UsageHistoryCache
    private let metricsReader: any LocalUsageMetricsReading
    private var pollingTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var consecutiveFailures: [UsageProviderID: Int] = [:]
    private var nextRefreshAt: [UsageProviderID: Date] = [:]

    public convenience init() {
        self.init(
            now: .now,
            codexConnector: CodexAppServerConnector(),
            claudeConnector: ClaudeOAuthConnector(),
            cache: UsageSnapshotCache(),
            historyCache: UsageHistoryCache(),
            metricsReader: LocalUsageMetricsReader()
        )
    }

    init(
        now: Date = .now,
        codexConnector: any UsageConnector = CodexAppServerConnector(),
        claudeConnector: (any UsageConnector)? = ClaudeOAuthConnector(),
        cache: UsageSnapshotCache = UsageSnapshotCache(),
        historyCache: UsageHistoryCache = UsageHistoryCache(),
        metricsReader: any LocalUsageMetricsReading = EmptyLocalUsageMetricsReader()
    ) {
        let resolvedConnectors = [claudeConnector, codexConnector].compactMap { $0 }
        connectors = resolvedConnectors
        self.cache = cache
        self.historyCache = historyCache
        self.metricsReader = metricsReader
        let cached = cache.load()
        history = historyCache.load()
        snapshots = UsageProviderID.allCases.map { provider in
            cached[provider].map(Self.cachedSnapshot) ?? Self.unavailable(provider, now: now)
        }
        connectionStatuses = UsageProviderID.allCases.compactMap { provider in
            guard resolvedConnectors.contains(where: { $0.providerID == provider }) else { return nil }
            return ProviderConnectionStatus(
                id: provider,
                phase: .checking,
                message: AppLanguage.current.text(
                    "Checking the connection…",
                    "Comprobando la conexión…"
                )
            )
        }
        nextRefreshAt = Dictionary(uniqueKeysWithValues: connectors.map { ($0.providerID, .distantPast) })
    }

    public var highestPercent: Int {
        Int(snapshots.compactMap(\.highestPercent).max() ?? 0)
    }

    public var overallSeverity: UsageSeverity {
        snapshots.map(\.severity).max() ?? .unavailable
    }

    public var requiresUserAction: Bool {
        connectionStatuses.contains { status in
            if case .actionRequired = status.phase { return true }
            return false
        }
    }

    public func refresh(force: Bool = true, allowInteraction: Bool = true) async {
        guard !isRefreshing else { return }
        let refreshStartedAt = Date.now
        let dueConnectors = connectors.filter { connector in
            force || (nextRefreshAt[connector.providerID] ?? .distantPast) <= refreshStartedAt
        }
        guard !dueConnectors.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let outcomes = await withTaskGroup(of: ConnectorOutcome.self) { group in
            for connector in dueConnectors {
                group.addTask {
                    do {
                        return ConnectorOutcome(
                            providerID: connector.providerID,
                            value: .success(
                                try await connector.fetchSnapshot(allowInteraction: allowInteraction)
                            )
                        )
                    } catch {
                        return ConnectorOutcome(
                            providerID: connector.providerID,
                            value: .failure(
                                error: error as? UsageConnectorError,
                                message: error.localizedDescription,
                                retryAfter: (error as? UsageConnectorError)?.retryAfter
                            )
                        )
                    }
                }
            }
            var collected: [ConnectorOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        var receivedLiveData = false
        var snapshotsNeedingMetrics: [ProviderUsageSnapshot] = []
        for outcome in outcomes {
            switch outcome.value {
            case .success(let snapshot):
                // Connector snapshots only contain quota windows. Keep the last
                // successfully indexed local totals until a newer metrics scan
                // replaces them; a transient bookmark/indexing failure must not
                // erase cost and token data from the UI or the cache.
                let snapshot = preservingWeeklyTotals(in: snapshot)
                replace(snapshot)
                replaceConnectionStatus(ProviderConnectionStatus(
                    id: outcome.providerID,
                    phase: .connected,
                    message: snapshot.message ?? AppLanguage.current.text("Connected", "Conectado")
                ))
                consecutiveFailures[outcome.providerID] = 0
                let interval = PollingPolicy.interval(
                    for: snapshot.severity,
                    consecutiveFailures: 0
                )
                nextRefreshAt[outcome.providerID] = .now.addingTimeInterval(Self.seconds(interval))
                receivedLiveData = receivedLiveData || snapshot.source == .live
                snapshotsNeedingMetrics.append(snapshot)
            case .failure(let error, let message, let retryAfter):
                replaceConnectionStatus(Self.connectionStatus(
                    providerID: outcome.providerID,
                    error: error,
                    message: message
                ))
                let failures = (consecutiveFailures[outcome.providerID] ?? 0) + 1
                consecutiveFailures[outcome.providerID] = failures
                let existing = snapshots.first { $0.id == outcome.providerID }
                let fallback = existing.flatMap { snapshot -> ProviderUsageSnapshot? in
                    guard snapshot.highestPercent != nil else { return nil }
                    return ProviderUsageSnapshot(
                        id: outcome.providerID,
                        session: snapshot.session,
                        weekly: snapshot.weekly,
                        observedAt: snapshot.observedAt,
                        source: .cached,
                        message: message,
                        weeklyTotals: snapshot.weeklyTotals
                    )
                }
                let unresolved = fallback
                    ?? Self.unavailable(outcome.providerID, now: .now, message: message)
                replace(unresolved)
                snapshotsNeedingMetrics.append(unresolved)

                let backoff = Self.seconds(
                    PollingPolicy.interval(for: .unavailable, consecutiveFailures: failures)
                )
                nextRefreshAt[outcome.providerID] = .now.addingTimeInterval(max(backoff, retryAfter ?? 0))
            }
        }

        if receivedLiveData {
            try? cache.save(snapshots)
            if let updatedHistory = try? historyCache.recording(snapshots, at: refreshStartedAt) {
                history = updatedHistory
            }
            WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetKind.summary)
        }
        scheduleMetricEnrichment(
            snapshotsNeedingMetrics,
            periodEnd: refreshStartedAt.addingTimeInterval(1)
        )
    }

    public func refreshWhenIdle(
        force: Bool = true,
        allowInteraction: Bool = true
    ) async {
        while isRefreshing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await refresh(force: force, allowInteraction: allowInteraction)
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(force: false, allowInteraction: false)
                let next = self.nextRefreshAt.values.min() ?? .now.addingTimeInterval(30)
                let delay = max(1, next.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    public func setAutomaticPollingEnabled(_ isEnabled: Bool) {
        if isEnabled {
            startPolling()
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private func replace(_ snapshot: ProviderUsageSnapshot) {
        if let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
    }

    private func preservingWeeklyTotals(
        in snapshot: ProviderUsageSnapshot
    ) -> ProviderUsageSnapshot {
        guard snapshot.weeklyTotals == nil,
              let previousTotals = snapshots.first(where: { $0.id == snapshot.id })?.weeklyTotals
        else { return snapshot }

        return ProviderUsageSnapshot(
            id: snapshot.id,
            session: snapshot.session,
            weekly: snapshot.weekly,
            observedAt: snapshot.observedAt,
            source: snapshot.source,
            message: snapshot.message,
            weeklyTotals: previousTotals
        )
    }

    private func replaceConnectionStatus(_ status: ProviderConnectionStatus) {
        if let index = connectionStatuses.firstIndex(where: { $0.id == status.id }) {
            connectionStatuses[index] = status
        } else {
            connectionStatuses.append(status)
        }
    }

    private func addingLocalMetrics(
        to snapshot: ProviderUsageSnapshot,
        periodEnd: Date
    ) async -> ProviderUsageSnapshot {
        let periodStart = snapshot.weekly.resetsAt?
            .addingTimeInterval(-7 * 24 * 60 * 60)
            ?? periodEnd.addingTimeInterval(-7 * 24 * 60 * 60)
        let totals = await metricsReader.weeklyTotals(
            for: snapshot.id,
            periodStart: periodStart,
            periodEnd: periodEnd
        )

        return ProviderUsageSnapshot(
            id: snapshot.id,
            session: snapshot.session,
            weekly: snapshot.weekly,
            observedAt: snapshot.observedAt,
            source: snapshot.source,
            message: snapshot.message,
            weeklyTotals: totals ?? snapshot.weeklyTotals
        )
    }

    private func scheduleMetricEnrichment(
        _ candidates: [ProviderUsageSnapshot],
        periodEnd: Date
    ) {
        guard metricsTask == nil else { return }
        metricsTask = Task { [weak self] in
            guard let self else { return }
            defer { metricsTask = nil }
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let enriched = await addingLocalMetrics(
                    to: candidate,
                    periodEnd: periodEnd
                )
                guard !Task.isCancelled else { return }
                guard snapshots.first(where: { $0.id == candidate.id })?.observedAt
                        == candidate.observedAt
                else { continue }
                replace(enriched)
            }

            let activityEnd = periodEnd
            let activityStart = Calendar.current.date(
                byAdding: .day,
                value: -60,
                to: activityEnd
            ) ?? activityEnd.addingTimeInterval(-60 * 24 * 60 * 60)
            var activityDates = Set<Date>()
            var dailyTokens: [UsageProviderID: [Date: Int]] = [:]
            for provider in UsageProviderID.allCases {
                let providerTotals = await metricsReader.dailyTokenTotals(
                    for: provider,
                    periodStart: activityStart,
                    periodEnd: activityEnd
                )
                guard !Task.isCancelled else { return }
                dailyTokens[provider] = providerTotals
                activityDates.formUnion(providerTotals.keys)
            }
            guard !Task.isCancelled else { return }
            if let updatedHistory = try? historyCache.applyingDailyTokens(
                dailyTokens,
                periodStart: activityStart,
                periodEnd: activityEnd
            ) {
                history = updatedHistory
            }
            guard !Task.isCancelled else { return }
            if let updatedHistory = try? historyCache.applyingActivityDates(
                activityDates,
                periodStart: activityStart,
                periodEnd: activityEnd
            ) {
                history = updatedHistory
            }
            guard !Task.isCancelled else { return }
            try? cache.save(snapshots)
            WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetKind.summary)
        }
    }

    private static func connectionStatus(
        providerID: UsageProviderID,
        error: UsageConnectorError?,
        message: String
    ) -> ProviderConnectionStatus {
        let phase: ProviderConnectionPhase
        switch error {
        case .permissionRequired:
            phase = .actionRequired(.grantPermission)
        case .notAuthenticated:
            phase = .actionRequired(.signIn)
        case .executableNotFound:
            phase = .actionRequired(.install)
        case .rateLimited, .launchFailed, .timedOut, .malformedResponse,
             .serverError, .missingUsageWindows, .none:
            phase = .retrying
        }
        return ProviderConnectionStatus(id: providerID, phase: phase, message: message)
    }

    private static func cachedSnapshot(_ snapshot: ProviderUsageSnapshot) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: snapshot.id,
            session: snapshot.session,
            weekly: snapshot.weekly,
            observedAt: snapshot.observedAt,
            source: .cached,
            message: AppLanguage.current.text("Last saved value", "Último dato guardado"),
            weeklyTotals: snapshot.weeklyTotals
        )
    }

    private static func unavailable(
        _ provider: UsageProviderID,
        now: Date,
        message: String? = nil
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: provider,
            session: UsageWindow(usedPercent: nil, resetsAt: nil),
            weekly: UsageWindow(usedPercent: nil, resetsAt: nil),
            observedAt: now,
            source: .unavailable,
            message: message ?? "\(AppLanguage.current.text("Looking for", "Buscando")) \(provider.displayName)…"
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private struct EmptyLocalUsageMetricsReader: LocalUsageMetricsReading {
    func weeklyTotals(
        for _: UsageProviderID,
        periodStart _: Date,
        periodEnd _: Date
    ) async -> WeeklyUsageTotals? {
        nil
    }
}

private struct ConnectorOutcome: Sendable {
    enum Value: Sendable {
        case success(ProviderUsageSnapshot)
        case failure(
            error: UsageConnectorError?,
            message: String,
            retryAfter: TimeInterval?
        )
    }

    let providerID: UsageProviderID
    let value: Value
}
