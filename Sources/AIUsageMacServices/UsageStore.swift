import AIUsageCore
import AIUsageProviderServices
import Foundation
import WidgetKit

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var providerStates: [ProviderRuntimeState]
    @Published public private(set) var history: UsageHistory
    @Published public private(set) var isRefreshing = false
    private let connectors: [any UsageConnector]
    private let cache: UsageSnapshotCache
    private let historyCache: UsageHistoryCache
    private let metricsReader: any LocalUsageMetricsReading
    private var pollingTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var pendingMetricCandidates: [UsageProviderID: ProviderUsageSnapshot] = [:]
    private var pendingMetricPeriodEnd: Date?
    private var verifyingProviders: Set<UsageProviderID> = []
    private var consecutiveFailures: [UsageProviderID: Int] = [:]
    private var nextRefreshAt: [UsageProviderID: Date] = [:]

    public var snapshots: [ProviderUsageSnapshot] {
        providerStates.map(\.snapshot)
    }

    public var connectionStatuses: [ProviderConnectionStatus] {
        providerStates.compactMap(\.connection)
    }

    public convenience init() {
        self.init(
            now: .now,
            codexConnector: Self.codexConnector(),
            claudeConnector: Self.claudeConnector(),
            cache: UsageSnapshotCache(),
            historyCache: UsageHistoryCache(),
            metricsReader: LocalUsageMetricsReader()
        )
    }

    init(
        now: Date = .now,
        codexConnector: any UsageConnector = UsageStore.codexConnector(),
        claudeConnector: (any UsageConnector)? = UsageStore.claudeConnector(),
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
        providerStates = UsageProviderID.allCases.map { provider in
            let snapshot = cached[provider].map(Self.cachedSnapshot)
                ?? Self.unavailable(provider, now: now)
            let connection = resolvedConnectors.contains(where: { $0.providerID == provider })
                ? ProviderConnectionStatus(
                    id: provider,
                    phase: .checking,
                    message: AppLanguage.current.text(
                        "Checking the connection…",
                        "Comprobando la conexión…"
                    )
                )
                : nil
            return ProviderRuntimeState(
                id: provider,
                snapshot: snapshot,
                connection: connection
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

    /// Produces a support artifact containing state and timing only. Provider
    /// messages, paths, account identifiers, percentages and credentials are
    /// intentionally excluded.
    public func diagnosticReportData(now: Date = .now) throws -> Data {
        let records = UsageProviderID.allCases.compactMap { provider -> UsageDiagnosticReport.Provider? in
            guard let status = connectionStatuses.first(where: { $0.id == provider }),
                  let snapshot = snapshots.first(where: { $0.id == provider })
            else { return nil }
            let nextRefresh = nextRefreshAt[provider] ?? now
            return UsageDiagnosticReport.Provider(
                id: provider,
                phase: status.phase.diagnosticName,
                dataState: status.dataState,
                source: snapshot.source,
                hasQuotaData: snapshot.highestPercent != nil,
                hasLocalTotals: snapshot.weeklyTotals != nil,
                observedAt: min(snapshot.observedAt, now),
                observationAgeSeconds: max(0, Int(now.timeIntervalSince(snapshot.observedAt))),
                consecutiveFailures: consecutiveFailures[provider, default: 0],
                nextRefreshInSeconds: max(0, Int(nextRefresh.timeIntervalSince(now))),
                isVerifyingAuthorization: verifyingProviders.contains(provider)
            )
        }
        let report = UsageDiagnosticReport(
            schemaVersion: 1,
            generatedAt: now,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            providers: records,
            retainedHistoryDays: history.days.count
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    public func refresh(
        force: Bool = true,
        allowInteraction: Bool = true,
        provider: UsageProviderID? = nil
    ) async {
        guard !isRefreshing else { return }
        let refreshStartedAt = Date.now
        let dueConnectors = connectors.filter { connector in
            (provider == nil || connector.providerID == provider)
                && (force || (nextRefreshAt[connector.providerID] ?? .distantPast) <= refreshStartedAt)
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
        var invalidatedDisconnectedCache = false
        var snapshotsNeedingMetrics: [ProviderUsageSnapshot] = []
        for outcome in outcomes {
            switch outcome.value {
            case .success(let snapshot):
                // Connector snapshots only contain quota windows. Keep the last
                // successfully indexed local totals until a newer metrics scan
                // replaces them; a transient bookmark/indexing failure must not
                // erase cost and token data from the UI or the cache.
                let snapshot = preservingWeeklyTotals(in: snapshot)
                replace(snapshot: snapshot, status: ProviderConnectionStatus(
                    id: outcome.providerID,
                    phase: .connected,
                    dataState: Self.dataState(for: snapshot, now: refreshStartedAt),
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
                let existing = snapshots.first { $0.id == outcome.providerID }
                let requiresSignIn: Bool
                if case .notAuthenticated = error {
                    requiresSignIn = true
                    invalidatedDisconnectedCache = true
                } else {
                    requiresSignIn = false
                }
                let hasLastKnownValue = existing?.highestPercent != nil && !requiresSignIn
                let isRateLimited: Bool
                if case .rateLimited = error {
                    isRateLimited = true
                } else {
                    isRateLimited = false
                }
                let status: ProviderConnectionStatus
                if verifyingProviders.contains(outcome.providerID), !requiresSignIn {
                    status = Self.verifyingStatus(outcome.providerID)
                } else if isRateLimited, hasLastKnownValue, let existing {
                    status = ProviderConnectionStatus(
                        id: outcome.providerID,
                        phase: .connected,
                        dataState: existing.isStale(at: refreshStartedAt) ? .stale : .cached,
                        message: message
                    )
                } else {
                    status = Self.connectionStatus(
                        providerID: outcome.providerID,
                        error: error,
                        message: message,
                        hasLastKnownValue: hasLastKnownValue
                    )
                }
                // Provider throttling is an expected refresh delay, not a
                // connection failure. Keep diagnostics and backoff truthful.
                let failures = isRateLimited && hasLastKnownValue
                    ? consecutiveFailures[outcome.providerID, default: 0]
                    : (consecutiveFailures[outcome.providerID] ?? 0) + 1
                consecutiveFailures[outcome.providerID] = failures
                let fallback = existing.flatMap { snapshot -> ProviderUsageSnapshot? in
                    guard !requiresSignIn, snapshot.highestPercent != nil else { return nil }
                    return ProviderUsageSnapshot(
                        id: outcome.providerID,
                        session: snapshot.session,
                        weekly: snapshot.weekly,
                        observedAt: snapshot.observedAt,
                        source: .cached,
                        message: isRateLimited ? snapshot.message : message,
                        weeklyTotals: snapshot.weeklyTotals
                    )
                }
                let unresolved = fallback
                    ?? Self.unavailable(outcome.providerID, now: .now, message: message)
                replace(snapshot: unresolved, status: status)
                // A throttled provider with a saved quota is still connected.
                // Local token totals do not depend on the provider API, so keep
                // enriching them instead of making cost/tokens disappear while
                // the remote endpoint is temporarily rate limited.
                if status.isConnected {
                    snapshotsNeedingMetrics.append(unresolved)
                }

                let backoff = Self.seconds(
                    PollingPolicy.interval(for: .unavailable, consecutiveFailures: failures)
                )
                nextRefreshAt[outcome.providerID] = .now.addingTimeInterval(max(backoff, retryAfter ?? 0))
            }
        }

        if receivedLiveData || invalidatedDisconnectedCache {
            try? cache.save(snapshots)
            if receivedLiveData,
               let updatedHistory = try? historyCache.recording(snapshots, at: refreshStartedAt) {
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
        allowInteraction: Bool = true,
        provider: UsageProviderID? = nil
    ) async {
        while isRefreshing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await refresh(force: force, allowInteraction: allowInteraction, provider: provider)
    }

    /// OAuth completion and usage availability are not atomic for every provider.
    /// Keep the UI in a truthful verifying state while the new session propagates.
    func confirmAuthorization(
        for provider: UsageProviderID,
        retryDelays: [Duration] = [.zero, .seconds(2), .seconds(4), .seconds(8),
                                   .seconds(15), .seconds(30)]
    ) async -> Bool {
        verifyingProviders.insert(provider)
        replaceConnectionStatus(Self.verifyingStatus(provider))

        for delay in retryDelays {
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    verifyingProviders.remove(provider)
                    return false
                }
            }
            await refreshWhenIdle(
                force: true,
                allowInteraction: false,
                provider: provider
            )
            guard let status = connectionStatuses.first(where: { $0.id == provider }) else {
                continue
            }
            if status.isConnected {
                verifyingProviders.remove(provider)
                return true
            }
            if status.dataState == .reauthRequired {
                verifyingProviders.remove(provider)
                return false
            }
        }

        verifyingProviders.remove(provider)
        await refreshWhenIdle(force: true, allowInteraction: false, provider: provider)
        return connectionStatuses.first(where: { $0.id == provider })?.isConnected == true
    }

    /// The single entry point for an interactive provider connection. Views do
    /// not own connection errors or infer intermediate states themselves.
    @discardableResult
    public func connect(_ provider: UsageProviderID) async -> Bool {
        await connect(provider) {
            try await ProviderWebAuthentication.shared.signIn(provider)
        }
    }

    @discardableResult
    func connect(
        _ provider: UsageProviderID,
        authenticate: @escaping @MainActor () async throws -> Void
    ) async -> Bool {
        let previousSnapshot = snapshots.first { $0.id == provider }
        let previousStatus = connectionStatuses.first { $0.id == provider }
        beginReconnection(for: provider)

        do {
            try await authenticate()
            return await confirmAuthorization(for: provider)
        } catch {
            if ProviderWebAuthentication.isCancellation(error) {
                restoreConnection(
                    provider: provider,
                    snapshot: previousSnapshot,
                    status: previousStatus
                )
                return previousStatus?.isConnected == true
            }

            await refreshWhenIdle(force: true, allowInteraction: false, provider: provider)
            if connectionStatuses.first(where: { $0.id == provider })?.isConnected == true {
                return true
            }

            replace(Self.unavailable(provider, now: .now, message: error.localizedDescription))
            replaceConnectionStatus(ProviderConnectionStatus(
                id: provider,
                phase: .actionRequired(.signIn),
                dataState: .reauthRequired,
                message: error.localizedDescription
            ))
            try? cache.save(snapshots)
            WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetKind.summary)
            return false
        }
    }

    /// Starts an explicit sign-in attempt without continuing to present an old
    /// quota as the result of that attempt. Automatic refresh failures still
    /// retain the last known value; only a user-requested reconnection clears it.
    func beginReconnection(for provider: UsageProviderID) {
        let now = Date.now
        replace(
            snapshot: Self.unavailable(
                provider,
                now: now,
                message: AppLanguage.current.text("Connecting…", "Conectando…")
            ),
            status: ProviderConnectionStatus(
                id: provider,
                phase: .checking,
                dataState: .reauthRequired,
                message: AppLanguage.current.text("Connecting…", "Conectando…")
            )
        )
        consecutiveFailures[provider] = 0
        nextRefreshAt[provider] = .distantPast
        try? cache.save(snapshots)
        WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetKind.summary)
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
        if let index = providerStates.firstIndex(where: { $0.id == snapshot.id }) {
            providerStates[index].snapshot = snapshot
        } else {
            providerStates.append(ProviderRuntimeState(
                id: snapshot.id,
                snapshot: snapshot,
                connection: nil
            ))
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
        if let index = providerStates.firstIndex(where: { $0.id == status.id }) {
            providerStates[index].connection = status
        } else {
            providerStates.append(ProviderRuntimeState(
                id: status.id,
                snapshot: Self.unavailable(status.id, now: .now),
                connection: status
            ))
        }
    }

    private func replace(
        snapshot: ProviderUsageSnapshot,
        status: ProviderConnectionStatus
    ) {
        if let index = providerStates.firstIndex(where: { $0.id == snapshot.id }) {
            providerStates[index] = ProviderRuntimeState(
                id: snapshot.id,
                snapshot: snapshot,
                connection: status
            )
        } else {
            providerStates.append(ProviderRuntimeState(
                id: snapshot.id,
                snapshot: snapshot,
                connection: status
            ))
        }
    }

    private func restoreConnection(
        provider: UsageProviderID,
        snapshot: ProviderUsageSnapshot?,
        status: ProviderConnectionStatus?
    ) {
        let restoredSnapshot = snapshot ?? Self.unavailable(provider, now: .now)
        let restoredStatus = status ?? ProviderConnectionStatus(
                id: provider,
                phase: .actionRequired(.signIn),
                dataState: .reauthRequired,
                message: AppLanguage.current.text(
                    "Connect AI Usage to read your usage.",
                    "Conecta AI Usage para consultar tu uso."
                )
            )
        replace(snapshot: restoredSnapshot, status: restoredStatus)
        try? cache.save(snapshots)
        WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetKind.summary)
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
        for candidate in candidates {
            pendingMetricCandidates[candidate.id] = candidate
        }
        pendingMetricPeriodEnd = max(pendingMetricPeriodEnd ?? periodEnd, periodEnd)
        guard metricsTask == nil else { return }
        metricsTask = Task { [weak self] in
            guard let self else { return }
            defer { metricsTask = nil }
            while !pendingMetricCandidates.isEmpty {
                let batch = Array(pendingMetricCandidates.values)
                let batchPeriodEnd = pendingMetricPeriodEnd ?? .now
                pendingMetricCandidates.removeAll()
                pendingMetricPeriodEnd = nil
                await enrichLocalMetrics(batch, periodEnd: batchPeriodEnd)
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func enrichLocalMetrics(
        _ candidates: [ProviderUsageSnapshot],
        periodEnd: Date
    ) async {
        let connectedProviderIDs = Set(
            connectionStatuses.filter(\.isConnected).map(\.id)
        )
        for candidate in candidates where connectedProviderIDs.contains(candidate.id) {
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
        for provider in connectedProviderIDs {
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

    private static func connectionStatus(
        providerID: UsageProviderID,
        error: UsageConnectorError?,
        message: String,
        hasLastKnownValue: Bool
    ) -> ProviderConnectionStatus {
        let phase: ProviderConnectionPhase
        let displayMessage: String
        switch error {
        case .permissionRequired:
            phase = .actionRequired(.grantPermission)
            displayMessage = message
        case .notAuthenticated:
            phase = .actionRequired(.signIn)
            displayMessage = hasLastKnownValue
                ? AppLanguage.current.text(
                    "Connect AI Usage to refresh the last saved value.",
                    "Conecta AI Usage para actualizar el último dato guardado."
                )
                : AppLanguage.current.text(
                    "Connect AI Usage to read your usage.",
                    "Conecta AI Usage para consultar tu uso."
                )
        case .executableNotFound:
            phase = .actionRequired(.install)
            displayMessage = message
        case .missingUsageWindows:
            phase = .retrying
            displayMessage = AppLanguage.current.text(
                "\(providerID.displayName) did not return usage limits.",
                "\(providerID.displayName) no devolvió los límites de uso."
            )
        case .rateLimited, .launchFailed, .timedOut, .malformedResponse,
             .serverError, .none:
            phase = .retrying
            displayMessage = message
        }
        let dataState: ProviderDataState
        if case .notAuthenticated = error {
            dataState = .reauthRequired
        } else if hasLastKnownValue {
            dataState = .stale
        } else {
            dataState = .temporarilyUnavailable
        }
        return ProviderConnectionStatus(
            id: providerID,
            phase: phase,
            dataState: dataState,
            message: displayMessage
        )
    }

    private static func verifyingStatus(_ provider: UsageProviderID) -> ProviderConnectionStatus {
        ProviderConnectionStatus(
            id: provider,
            phase: .checking,
            dataState: .temporarilyUnavailable,
            message: AppLanguage.current.text(
                "Authorized · Waiting for usage data…",
                "Autorizado · Esperando los datos de uso…"
            )
        )
    }

    private static func dataState(
        for snapshot: ProviderUsageSnapshot,
        now: Date
    ) -> ProviderDataState {
        switch snapshot.source {
        case .live, .mock: .live
        case .cached where snapshot.isStale(at: now): .stale
        case .cached: .cached
        case .unavailable: .temporarilyUnavailable
        }
    }

    private static func cachedSnapshot(_ snapshot: ProviderUsageSnapshot) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: snapshot.id,
            session: snapshot.session,
            weekly: snapshot.weekly,
            observedAt: snapshot.observedAt,
            source: .cached,
            message: snapshot.message ?? AppLanguage.current.text(
                "Last saved value",
                "Último dato guardado"
            ),
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

    private static func claudeConnector() -> any UsageConnector {
        ResilientUsageConnector(
            direct: DirectUsageConnector(adapter: ClaudeDirectAdapter()),
            localFallback: ClaudeStatusLineFallback()
        )
    }

    private static func codexConnector() -> any UsageConnector {
        ResilientUsageConnector(
            direct: DirectUsageConnector(adapter: CodexDirectAdapter()),
            localFallback: CodexAppServerFallback()
        )
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
