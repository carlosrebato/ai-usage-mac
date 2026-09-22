import Foundation
import Combine
import Testing
import AIUsageCore
@testable import AIUsageMacServices

private struct FailingConnector: UsageConnector {
    let providerID: UsageProviderID
    let error: UsageConnectorError

    init(
        providerID: UsageProviderID = .codex,
        error: UsageConnectorError = .timedOut
    ) {
        self.providerID = providerID
        self.error = error
    }

    func fetchSnapshot(allowInteraction: Bool) async throws -> ProviderUsageSnapshot {
        throw error
    }
}

private struct FixedConnector: UsageConnector {
    let providerID = UsageProviderID.codex
    let snapshot: ProviderUsageSnapshot

    func fetchSnapshot(allowInteraction: Bool) async throws -> ProviderUsageSnapshot { snapshot }
}

private enum ScriptedConnectorStep: Sendable {
    case success(ProviderUsageSnapshot)
    case failure(UsageConnectorError)
}

private actor ScriptedConnector: UsageConnector {
    nonisolated let providerID: UsageProviderID
    private var steps: [ScriptedConnectorStep]

    init(providerID: UsageProviderID, steps: [ScriptedConnectorStep]) {
        self.providerID = providerID
        self.steps = steps
    }

    func fetchSnapshot(allowInteraction _: Bool) async throws -> ProviderUsageSnapshot {
        guard !steps.isEmpty else { throw UsageConnectorError.serverError("Guion agotado") }
        switch steps.removeFirst() {
        case .success(let snapshot): return snapshot
        case .failure(let error): throw error
        }
    }
}

private actor GatedMetricsReader: LocalUsageMetricsReading {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func weeklyTotals(
        for _: UsageProviderID,
        periodStart _: Date,
        periodEnd _: Date
    ) async -> WeeklyUsageTotals? {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return nil
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RecordingMetricsReader: LocalUsageMetricsReading {
    private var weeklyProviders: [UsageProviderID] = []
    private var dailyProviders: [UsageProviderID] = []

    func weeklyTotals(
        for provider: UsageProviderID,
        periodStart _: Date,
        periodEnd _: Date
    ) async -> WeeklyUsageTotals? {
        weeklyProviders.append(provider)
        return nil
    }

    func dailyTokenTotals(
        for provider: UsageProviderID,
        periodStart _: Date,
        periodEnd _: Date
    ) async -> [Date: Int] {
        dailyProviders.append(provider)
        return [:]
    }

    func waitForDailyScan() async {
        while dailyProviders.isEmpty { await Task.yield() }
    }

    func requestedProviders() -> Set<UsageProviderID> {
        Set(weeklyProviders + dailyProviders)
    }
}

private struct FixedMetricsReader: LocalUsageMetricsReading {
    let totals: WeeklyUsageTotals

    func weeklyTotals(
        for _: UsageProviderID,
        periodStart _: Date,
        periodEnd _: Date
    ) async -> WeeklyUsageTotals? {
        totals
    }
}

private actor SequencedGatedMetricsReader: LocalUsageMetricsReading {
    private var weeklyCalls = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    func weeklyTotals(
        for _: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) async -> WeeklyUsageTotals? {
        weeklyCalls += 1
        let call = weeklyCalls
        if call == 1 {
            await withCheckedContinuation { firstCallContinuation = $0 }
        }
        return WeeklyUsageTotals(
            inputTokens: call * 100,
            cachedInputTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            equivalentCostUSD: nil,
            hasUnpricedModels: false,
            periodStart: periodStart,
            periodEnd: periodEnd
        )
    }

    func waitForFirstCall() async -> Bool {
        for _ in 0..<10_000 {
            if weeklyCalls >= 1 { return true }
            await Task.yield()
        }
        return false
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }

    func waitForWeeklyCalls(_ count: Int) async -> Bool {
        for _ in 0..<10_000 {
            if weeklyCalls >= count { return true }
            await Task.yield()
        }
        return false
    }
}

struct UsageStoreTests {
    @Test @MainActor func fakeOnboardingCoversPermissionFailureRetryAndSuccess() async {
        let claude = ScriptedConnector(
            providerID: .claude,
            steps: [
                .failure(.permissionRequired("Selecciona la carpeta de Claude")),
                .success(claudeSnapshot(percent: 24, source: .live))
            ]
        )
        let codex = ScriptedConnector(
            providerID: .codex,
            steps: [
                .failure(.timedOut),
                .success(codexSnapshot(percent: 31, source: .live))
            ]
        )
        let store = UsageStore(
            codexConnector: codex,
            claudeConnector: claude,
            cache: temporaryCache()
        )

        await store.refresh(force: true, allowInteraction: false)

        #expect(store.connectionStatuses.first { $0.id == .claude }?.phase
                == .actionRequired(.grantPermission))
        #expect(store.connectionStatuses.first { $0.id == .codex }?.phase == .retrying)
        #expect(!store.isRefreshing)

        await store.refreshWhenIdle(force: true, allowInteraction: true)

        #expect(store.connectionStatuses.allSatisfy { $0.isConnected })
        #expect(store.snapshots.first { $0.id == .claude }?.session.usedPercent == 24)
        #expect(store.snapshots.first { $0.id == .codex }?.weekly.usedPercent == 31)
        #expect(!store.isRefreshing)
    }

    @Test @MainActor func localMetricsNeverHoldTheOnboardingSpinnerOpen() async {
        let metrics = GatedMetricsReader()
        let store = UsageStore(
            codexConnector: FixedConnector(
                snapshot: codexSnapshot(percent: 18, source: .live)
            ),
            claudeConnector: nil,
            cache: temporaryCache(),
            metricsReader: metrics
        )

        await store.refresh()
        await metrics.waitUntilStarted()

        #expect(store.connectionStatuses.first { $0.id == .codex }?.phase == .connected)
        #expect(!store.isRefreshing)

        await metrics.release()
        await Task.yield()
    }

    @Test @MainActor func aNewMetricsCandidateIsCoalescedInsteadOfDropped() async {
        let first = ProviderUsageSnapshot(
            id: .codex,
            session: UsageWindow(usedPercent: 10, resetsAt: nil),
            weekly: UsageWindow(usedPercent: 10, resetsAt: nil),
            observedAt: Date(timeIntervalSince1970: 100),
            source: .live,
            message: "First"
        )
        let second = ProviderUsageSnapshot(
            id: .codex,
            session: UsageWindow(usedPercent: 20, resetsAt: nil),
            weekly: UsageWindow(usedPercent: 20, resetsAt: nil),
            observedAt: Date(timeIntervalSince1970: 200),
            source: .live,
            message: "Second"
        )
        let connector = ScriptedConnector(
            providerID: .codex,
            steps: [.success(first), .success(second)]
        )
        let metrics = SequencedGatedMetricsReader()
        let store = UsageStore(
            codexConnector: connector,
            claudeConnector: nil,
            cache: temporaryCache(),
            metricsReader: metrics
        )

        await store.refresh(provider: .codex)
        #expect(await metrics.waitForFirstCall())
        await store.refresh(provider: .codex)
        await metrics.releaseFirstCall()
        #expect(await metrics.waitForWeeklyCalls(2))
        for _ in 0..<20 { await Task.yield() }

        let snapshot = store.snapshots.first { $0.id == .codex }
        #expect(snapshot?.weekly.usedPercent == 20)
        #expect(snapshot?.weeklyTotals?.inputTokens == 200)
    }

    @Test @MainActor func refreshPublishesLiveCodexData() async {
        let live = codexSnapshot(percent: 18, source: .live)
        let cache = temporaryCache()
        let store = UsageStore(
            codexConnector: FixedConnector(snapshot: live),
            claudeConnector: nil,
            cache: cache
        )

        await store.refresh()

        let codex = store.snapshots.first { $0.id == .codex }
        #expect(codex?.weekly.usedPercent == 18)
        #expect(codex?.source == .live)
        #expect(store.connectionStatuses.first { $0.id == .codex }?.phase == .connected)
    }

    @Test @MainActor func openingStalePanelRecoversWithoutWaitingForBackgroundTimer() async throws {
        let cache = temporaryCache()
        let old = ProviderUsageSnapshot(
            id: .codex,
            session: UsageWindow(usedPercent: 55, resetsAt: .now.addingTimeInterval(-60)),
            weekly: UsageWindow(usedPercent: 30, resetsAt: nil),
            observedAt: .now.addingTimeInterval(-4 * 60 * 60),
            source: .live,
            message: nil
        )
        try cache.save([old])
        let fresh = codexSnapshot(percent: 60, source: .live)
        let store = UsageStore(
            codexConnector: FixedConnector(snapshot: fresh),
            claudeConnector: nil,
            cache: cache
        )

        await store.refreshStaleOnPresentation()

        let snapshot = store.snapshots.first { $0.id == .codex }
        #expect(snapshot?.source == .live)
        #expect(snapshot?.weekly.usedPercent == fresh.weekly.usedPercent)
    }

    @Test @MainActor func liveRefreshDoesNotErasePreviouslyIndexedWeeklyTotals() async throws {
        let cache = temporaryCache()
        let totals = WeeklyUsageTotals(
            inputTokens: 1_200,
            cachedInputTokens: 300,
            cacheWriteTokens: 0,
            outputTokens: 500,
            reasoningTokens: 0,
            equivalentCostUSD: 4.25,
            hasUnpricedModels: false,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 100)
        )
        let cached = ProviderUsageSnapshot(
            id: .codex,
            session: UsageWindow(usedPercent: nil, resetsAt: nil),
            weekly: UsageWindow(usedPercent: 40, resetsAt: nil),
            observedAt: Date(timeIntervalSince1970: 50),
            source: .live,
            message: "Indexed",
            weeklyTotals: totals
        )
        try cache.save([cached])
        let store = UsageStore(
            codexConnector: FixedConnector(
                snapshot: codexSnapshot(percent: 41, source: .live)
            ),
            claudeConnector: nil,
            cache: cache
        )

        await store.refresh()

        let refreshed = store.snapshots.first { $0.id == .codex }
        #expect(refreshed?.weekly.usedPercent == 41)
        #expect(refreshed?.weeklyTotals == totals)
    }

    @Test @MainActor func failureKeepsTheLastKnownValue() async throws {
        let cache = temporaryCache()
        try cache.save([codexSnapshot(percent: 54, source: .live)])
        let store = UsageStore(
            codexConnector: FailingConnector(),
            claudeConnector: nil,
            cache: cache
        )

        await store.refresh()

        let codex = store.snapshots.first { $0.id == .codex }
        #expect(codex?.weekly.usedPercent == 54)
        #expect(codex?.source == .cached)
        #expect(codex?.message == UsageConnectorError.timedOut.localizedDescription)
    }

    @Test @MainActor func rateLimitKeepsAConnectedCachedStateAndPlan() async throws {
        let cache = temporaryCache()
        let localTotals = WeeklyUsageTotals(
            inputTokens: 1_000,
            cachedInputTokens: 2_000,
            cacheWriteTokens: 300,
            outputTokens: 400,
            reasoningTokens: 100,
            equivalentCostUSD: 1.23,
            hasUnpricedModels: false,
            periodStart: Date.now.addingTimeInterval(-7 * 24 * 60 * 60),
            periodEnd: .now
        )
        let previous = ProviderUsageSnapshot(
            id: .claude,
            session: UsageWindow(
                usedPercent: 7,
                resetsAt: Date.now.addingTimeInterval(3 * 60 * 60)
            ),
            weekly: UsageWindow(
                usedPercent: 4,
                resetsAt: Date.now.addingTimeInterval(4 * 24 * 60 * 60)
            ),
            observedAt: .now,
            source: .live,
            message: "Plan Max 5x"
        )
        try cache.save([previous])
        let store = UsageStore(
            codexConnector: FailingConnector(),
            claudeConnector: FailingConnector(
                providerID: .claude,
                error: .rateLimited(retryAfter: 300)
            ),
            cache: cache,
            metricsReader: FixedMetricsReader(totals: localTotals)
        )

        await store.refresh(provider: .claude)
        for _ in 0..<50 where store.snapshots.first(where: { $0.id == .claude })?.weeklyTotals == nil {
            await Task.yield()
        }

        let status = store.connectionStatuses.first { $0.id == .claude }
        let snapshot = store.snapshots.first { $0.id == .claude }
        #expect(status?.phase == .connected)
        #expect(status?.dataState == .cached)
        #expect(status?.action == nil)
        #expect(snapshot?.source == .cached)
        #expect(snapshot?.message == "Plan Max 5x")
        #expect(snapshot?.session.resetsAt == previous.session.resetsAt)
        #expect(snapshot?.weekly.resetsAt == previous.weekly.resetsAt)
        #expect(snapshot?.weeklyTotals == localTotals)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(
            UsageDiagnosticReport.self,
            from: store.diagnosticReportData()
        )
        let claude = report.providers.first { $0.id == .claude }
        #expect(claude?.phase == "connected")
        #expect(claude?.consecutiveFailures == 0)
        #expect((claude?.nextRefreshInSeconds ?? 0) >= 299)
    }

    @Test @MainActor func rateLimitWithoutSavedDataStillRetries() async {
        let store = UsageStore(
            codexConnector: FailingConnector(
                error: .rateLimited(retryAfter: 300)
            ),
            claudeConnector: nil,
            cache: temporaryCache()
        )

        await store.refresh()

        let status = store.connectionStatuses.first { $0.id == .codex }
        #expect(status?.phase == .retrying)
        #expect(status?.action == .retry)
        #expect(store.snapshots.first { $0.id == .codex }?.source == .unavailable)
    }

    @Test @MainActor func claudeFailureDoesNotHideCodexSuccess() async {
        let live = codexSnapshot(percent: 23, source: .live)
        let store = UsageStore(
            codexConnector: FixedConnector(snapshot: live),
            claudeConnector: FailingConnector(providerID: .claude),
            cache: temporaryCache()
        )

        await store.refresh()

        #expect(store.snapshots.first { $0.id == .codex }?.source == .live)
        #expect(store.snapshots.first { $0.id == .claude }?.source == .unavailable)
    }

    @Test @MainActor func disconnectedProviderIsNotEnrichedFromLocalMetrics() async {
        let metrics = RecordingMetricsReader()
        let store = UsageStore(
            codexConnector: FixedConnector(
                snapshot: codexSnapshot(percent: 23, source: .live)
            ),
            claudeConnector: FailingConnector(
                providerID: .claude,
                error: .notAuthenticated("Sign in.")
            ),
            cache: temporaryCache(),
            metricsReader: metrics
        )

        await store.refresh()
        await metrics.waitForDailyScan()

        #expect(await metrics.requestedProviders() == [.codex])
        #expect(store.snapshots.first { $0.id == .claude }?.weeklyTotals == nil)
    }

    @Test @MainActor func authorizationWaitsForUsageWindowsWithoutShowingReconnect() async {
        let claude = ScriptedConnector(
            providerID: .claude,
            steps: [
                .failure(.missingUsageWindows),
                .success(claudeSnapshot(percent: 19, source: .live))
            ]
        )
        let store = UsageStore(
            codexConnector: FixedConnector(
                snapshot: codexSnapshot(percent: 23, source: .live)
            ),
            claudeConnector: claude,
            cache: temporaryCache()
        )

        store.beginReconnection(for: .claude)
        let connected = await store.confirmAuthorization(
            for: .claude,
            retryDelays: [.zero, .zero]
        )

        #expect(connected)
        #expect(store.connectionStatuses.first { $0.id == .claude }?.isConnected == true)
        #expect(store.snapshots.first { $0.id == .claude }?.session.usedPercent == 19)
    }

    @Test @MainActor func cancelledReconnectRestoresTheExactPreviousState() async {
        let original = claudeSnapshot(percent: 27, source: .live)
        let store = UsageStore(
            codexConnector: FixedConnector(
                snapshot: codexSnapshot(percent: 23, source: .live)
            ),
            claudeConnector: ScriptedConnector(
                providerID: .claude,
                steps: [.success(original)]
            ),
            cache: temporaryCache()
        )
        await store.refresh(provider: .claude)
        let statusBefore = store.connectionStatuses.first { $0.id == .claude }
        let snapshotBefore = store.snapshots.first { $0.id == .claude }

        let connected = await store.connect(.claude) {
            throw CancellationError()
        }

        #expect(connected)
        #expect(store.connectionStatuses.first { $0.id == .claude } == statusBefore)
        #expect(store.snapshots.first { $0.id == .claude } == snapshotBefore)
    }

    @Test @MainActor func authenticationFailureHasOneCanonicalVisibleState() async {
        let store = UsageStore(
            codexConnector: FixedConnector(
                snapshot: codexSnapshot(percent: 23, source: .live)
            ),
            claudeConnector: FailingConnector(
                providerID: .claude,
                error: .notAuthenticated("No session")
            ),
            cache: temporaryCache()
        )
        let failure = NSError(
            domain: "AIUsageTests.Authentication",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Authorization rejected"]
        )

        let connected = await store.connect(.claude) { throw failure }
        let status = store.connectionStatuses.first { $0.id == .claude }
        let snapshot = store.snapshots.first { $0.id == .claude }

        #expect(!connected)
        #expect(status?.phase == .actionRequired(.signIn))
        #expect(status?.dataState == .reauthRequired)
        #expect(status?.message == "Authorization rejected")
        #expect(snapshot?.source == .unavailable)
        #expect(snapshot?.message == "Authorization rejected")
    }

    @Test @MainActor func diagnosticReportExcludesProviderMessagesAndSecrets() async throws {
        let secret = "SECRET-TOKEN /Users/alice/private"
        let store = UsageStore(
            codexConnector: FailingConnector(
                error: .serverError(secret)
            ),
            claudeConnector: nil,
            cache: temporaryCache()
        )
        await store.refresh()

        let data = try store.diagnosticReportData(
            now: Date(timeIntervalSince1970: 2_000)
        )
        let text = String(decoding: data, as: UTF8.self)

        #expect(!text.contains("SECRET-TOKEN"))
        #expect(!text.contains("/Users/alice"))
        #expect(text.contains("\"phase\" : \"retrying\""))
        #expect(text.contains("\"schemaVersion\" : 1"))
    }

    @Test @MainActor func publishedProviderStatesAreAlwaysInternallyCoherent() async {
        let claude = ScriptedConnector(
            providerID: .claude,
            steps: [
                .success(claudeSnapshot(percent: 18, source: .live)),
                .failure(.notAuthenticated("Sign in"))
            ]
        )
        let store = UsageStore(
            codexConnector: FixedConnector(
                snapshot: codexSnapshot(percent: 23, source: .live)
            ),
            claudeConnector: claude,
            cache: temporaryCache()
        )
        var violations: [ProviderRuntimeState] = []
        let observation = store.$providerStates.sink { states in
            violations.append(contentsOf: states.filter { state in
                guard let connection = state.connection else { return false }
                if connection.isConnected {
                    return state.snapshot.source == .unavailable
                        || state.snapshot.highestPercent == nil
                }
                if connection.dataState == .reauthRequired,
                   case .actionRequired(.signIn) = connection.phase {
                    return state.snapshot.source != .unavailable
                }
                return false
            })
        }

        await store.refresh(provider: .claude)
        await store.refresh(provider: .claude)
        observation.cancel()

        #expect(violations.isEmpty)
    }

    @Test @MainActor func codexSuccessDoesNotDeleteCachedClaudeOnRelaunch() async throws {
        let cache = temporaryCache()
        try cache.save([
            claudeSnapshot(percent: 21, source: .live),
            codexSnapshot(percent: 62, source: .live)
        ])
        let store = UsageStore(
            codexConnector: FixedConnector(snapshot: codexSnapshot(percent: 65, source: .live)),
            claudeConnector: FailingConnector(
                providerID: .claude,
                error: .permissionRequired("Permite acceso a Claude Desktop")
            ),
            cache: cache
        )

        await store.refresh(force: true, allowInteraction: false)

        let relaunched = UsageStore(
            codexConnector: FailingConnector(),
            claudeConnector: FailingConnector(providerID: .claude),
            cache: cache
        )
        let claude = relaunched.snapshots.first { $0.id == .claude }
        #expect(claude?.session.usedPercent == 21)
        #expect(claude?.source == .cached)
    }

    @Test @MainActor func desktopPermissionBecomesAnExplicitSetupAction() async {
        let store = UsageStore(
            codexConnector: FixedConnector(snapshot: codexSnapshot(percent: 12, source: .live)),
            claudeConnector: FailingConnector(
                providerID: .claude,
                error: .permissionRequired("Permite acceso a Claude Desktop")
            ),
            cache: temporaryCache()
        )

        await store.refresh(force: true, allowInteraction: false)

        let claude = store.connectionStatuses.first { $0.id == .claude }
        #expect(claude?.phase == .actionRequired(.grantPermission))
        #expect(claude?.action == .grantPermission)
        #expect(store.requiresUserAction)
    }

    @Test @MainActor func missingCodexBecomesAnInstallAction() async {
        let store = UsageStore(
            codexConnector: FailingConnector(error: .executableNotFound),
            claudeConnector: nil,
            cache: temporaryCache()
        )

        await store.refresh()

        let codex = store.connectionStatuses.first { $0.id == .codex }
        #expect(codex?.phase == .actionRequired(.install))
    }

    @Test @MainActor func transientFailureOffersRetryWithoutPretendingLoginIsMissing() async {
        let store = UsageStore(
            codexConnector: FailingConnector(error: .timedOut),
            claudeConnector: nil,
            cache: temporaryCache()
        )

        await store.refresh()

        let codex = store.connectionStatuses.first { $0.id == .codex }
        #expect(codex?.phase == .retrying)
        #expect(codex?.action == .retry)
        #expect(!store.requiresUserAction)
    }

    @Test @MainActor func missingClaudeWindowsNamesClaudeInsteadOfCodex() async {
        let store = UsageStore(
            codexConnector: FixedConnector(
                snapshot: codexSnapshot(percent: 18, source: .live)
            ),
            claudeConnector: FailingConnector(
                providerID: .claude,
                error: .missingUsageWindows
            ),
            cache: temporaryCache()
        )

        await store.refresh()

        let claude = store.connectionStatuses.first { $0.id == .claude }
        #expect(claude?.message == "Claude Code did not return usage limits.")
    }

    @Test @MainActor func missingAppCredentialInvalidatesCachedValueWithoutLoggingOutOtherApps() async throws {
        let cache = temporaryCache()
        try cache.save([codexSnapshot(percent: 54, source: .live)])
        let store = UsageStore(
            codexConnector: FailingConnector(
                error: .notAuthenticated("Sign in to continue.")
            ),
            claudeConnector: nil,
            cache: cache
        )

        await store.refresh()

        let codex = store.connectionStatuses.first { $0.id == .codex }
        #expect(codex?.phase == .actionRequired(.signIn))
        #expect(codex?.dataState == .reauthRequired)
        #expect(codex?.message == "Connect AI Usage to read your usage.")
        #expect(store.snapshots.first { $0.id == .codex }?.source == .unavailable)
        #expect(cache.load()[.codex] == nil)
    }

    @Test @MainActor func explicitReconnectionInvalidatesTheSavedProviderValue() throws {
        let cache = temporaryCache()
        try cache.save([
            claudeSnapshot(percent: 21, source: .live),
            codexSnapshot(percent: 54, source: .live)
        ])
        let store = UsageStore(
            codexConnector: FailingConnector(error: .notAuthenticated("Sign in.")),
            claudeConnector: FailingConnector(
                providerID: .claude,
                error: .notAuthenticated("Sign in.")
            ),
            cache: cache
        )

        store.beginReconnection(for: .codex)

        let codex = store.snapshots.first { $0.id == .codex }
        #expect(codex?.source == .unavailable)
        #expect(codex?.highestPercent == nil)
        #expect(store.connectionStatuses.first { $0.id == .codex }?.phase == .checking)
        #expect(cache.load()[.codex] == nil)
        #expect(cache.load()[.claude]?.highestPercent == 64)
    }

    private func temporaryCache() -> UsageSnapshotCache {
        UsageSnapshotCache(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("usage-cache.json")
        )
    }

    private func codexSnapshot(percent: Double, source: UsageSource) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: .codex,
            session: UsageWindow(usedPercent: nil, resetsAt: nil),
            weekly: UsageWindow(usedPercent: percent, resetsAt: nil),
            observedAt: Date(timeIntervalSince1970: 100),
            source: source,
            message: "Test"
        )
    }

    private func claudeSnapshot(percent: Double, source: UsageSource) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: .claude,
            session: UsageWindow(usedPercent: percent, resetsAt: nil),
            weekly: UsageWindow(usedPercent: 64, resetsAt: nil),
            observedAt: Date(timeIntervalSince1970: 100),
            source: source,
            message: "Test"
        )
    }
}
