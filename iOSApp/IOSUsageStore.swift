import AIUsageCore
import AIUsageProviderServices
import Foundation

@MainActor
final class IOSUsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderUsageSnapshot] = []
    @Published private(set) var states: [UsageProviderID: ProviderDataState] = [
        .claude: .reauthRequired,
        .codex: .reauthRequired
    ]
    @Published private(set) var messages: [UsageProviderID: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published var isDemoMode = ProcessInfo.processInfo.arguments.contains("--app-review-demo")

    private let adapters: [UsageProviderID: any DirectUsageAdapter]
    private var lastRefresh: Date?

    init(
        claude: any DirectUsageAdapter = ClaudeDirectAdapter(),
        codex: any DirectUsageAdapter = CodexDirectAdapter()
    ) {
        adapters = [.claude: claude, .codex: codex]
        if isDemoMode { applyDemo() }
    }

    func refresh(force: Bool = false) async {
        if isDemoMode {
            applyDemo()
            return
        }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = .now
        }

        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for (provider, adapter) in adapters {
                group.addTask {
                    do {
                        return Outcome(provider: provider, result: .success(try await adapter.fetchSnapshot()))
                    } catch {
                        return Outcome(provider: provider, result: .failure(error))
                    }
                }
            }
            var values: [Outcome] = []
            for await outcome in group { values.append(outcome) }
            return values
        }

        for outcome in outcomes {
            switch outcome.result {
            case .success(let snapshot):
                replace(snapshot)
                states[outcome.provider] = .live
                messages[outcome.provider] = snapshot.message
            case .failure(let error):
                let directError = error as? DirectUsageError
                let oauthError = error as? ProviderOAuthError
                if directError?.requiresReauthentication == true
                    || oauthError == .reauthenticationRequired
                    || oauthError == .missingRefreshToken {
                    states[outcome.provider] = .reauthRequired
                } else if snapshots.contains(where: { $0.id == outcome.provider }) {
                    states[outcome.provider] = .stale
                } else {
                    states[outcome.provider] = .temporarilyUnavailable
                }
                messages[outcome.provider] = error.localizedDescription
            }
        }
    }

    func signIn(_ provider: UsageProviderID) async {
        do {
            try await ProviderWebAuthentication.shared.signIn(provider)
            messages[provider] = nil
            await refresh(force: true)
        } catch {
            messages[provider] = error.localizedDescription
        }
    }

    func signOut(_ provider: UsageProviderID) async {
        do {
            try await ProviderAccounts.shared.signOut(provider)
            snapshots.removeAll { $0.id == provider }
            states[provider] = .reauthRequired
            messages[provider] = nil
        } catch {
            messages[provider] = error.localizedDescription
        }
    }

    func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
        if enabled {
            applyDemo()
        } else {
            snapshots = []
            states = [.claude: .reauthRequired, .codex: .reauthRequired]
            messages = [:]
        }
    }

    private func replace(_ snapshot: ProviderUsageSnapshot) {
        if let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
            snapshots.sort { $0.id.rawValue < $1.id.rawValue }
        }
    }

    private func applyDemo() {
        let now = Date.now
        snapshots = [
            ProviderUsageSnapshot(
                id: .claude,
                session: UsageWindow(usedPercent: 28, resetsAt: now.addingTimeInterval(2 * 3600)),
                weekly: UsageWindow(usedPercent: 43, resetsAt: now.addingTimeInterval(4 * 86_400)),
                observedAt: now,
                source: .mock,
                message: "App Review demo"
            ),
            ProviderUsageSnapshot(
                id: .codex,
                session: UsageWindow(usedPercent: 64, resetsAt: now.addingTimeInterval(90 * 60)),
                weekly: UsageWindow(usedPercent: 37, resetsAt: now.addingTimeInterval(5 * 86_400)),
                observedAt: now,
                source: .mock,
                message: "App Review demo"
            )
        ]
        states = [.claude: .live, .codex: .live]
        messages = [:]
    }
}

private struct Outcome: @unchecked Sendable {
    let provider: UsageProviderID
    let result: Result<ProviderUsageSnapshot, Error>
}
