import Foundation
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
