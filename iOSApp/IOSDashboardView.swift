import AIUsageCore
import AIUsageDesignSystem
import SwiftUI

struct IOSDashboardView: View {
    @EnvironmentObject private var store: IOSUsageStore

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if store.isDemoMode {
                        demoBanner
                    }
                    ForEach(UsageProviderID.allCases, id: \.self) { provider in
                        providerCard(provider)
                    }
                    privacyNote
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AI Usage")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(store.isDemoMode ? "Exit demo" : "App Review demo") {
                            store.setDemoMode(!store.isDemoMode)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh(force: true) }
                    } label: {
                        if store.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isRefreshing || store.isDemoMode)
                }
            }
        }
    }

    private func providerCard(_ provider: UsageProviderID) -> some View {
        let snapshot = store.snapshots.first { $0.id == provider }
        let state = store.states[provider] ?? .temporarilyUnavailable
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(provider.displayName, systemImage: provider.symbolName)
                    .font(.headline)
                Spacer()
                stateBadge(state)
            }

            if let snapshot {
                usageRow("Session", window: snapshot.session)
                usageRow("Weekly", window: snapshot.weekly)
                Text(freshness(snapshot.observedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(store.messages[provider] ?? "Connect this device to read current limits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !store.isDemoMode {
                HStack {
                    if state == .reauthRequired {
                        Button("Sign in") { Task { await store.signIn(provider) } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Sign out", role: .destructive) {
                            Task { await store.signOut(provider) }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func usageRow(_ title: String, window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .monospacedDigit()
                    .font(.headline)
            }
            ProgressView(value: window.normalizedPercent, total: 100)
                .tint(window.normalizedPercent >= 85 ? .red : .accentColor)
            if let reset = window.resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stateBadge(_ state: ProviderDataState) -> some View {
        Text(stateLabel(state))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stateColor(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stateColor(state).opacity(0.14), in: Capsule())
    }

    private func stateColor(_ state: ProviderDataState) -> Color {
        switch state {
        case .live: UsageTheme.green
        case .cached, .stale: UsageTheme.cached
        case .reauthRequired: UsageTheme.amber
        case .temporarilyUnavailable: UsageTheme.red
        }
    }

    private func stateLabel(_ state: ProviderDataState) -> String {
        switch state {
        case .live: "LIVE"
        case .cached: "CACHED"
        case .stale: "STALE"
        case .reauthRequired: "SIGN IN"
        case .temporarilyUnavailable: "UNAVAILABLE"
        }
    }

    private func freshness(_ date: Date) -> String {
        "Updated \(date.formatted(.relative(presentation: .named)))"
    }

    private var demoBanner: some View {
        Label("Synthetic data for App Review — no account is connected", systemImage: "testtube.2")
            .font(.footnote.weight(.medium))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }

    private var privacyNote: some View {
        Text("Independent, not affiliated with Anthropic or OpenAI. Credentials stay in this device's Keychain and are sent only to the selected provider.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}
