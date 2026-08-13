import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppPreferenceKey.automaticRefresh) private var automaticRefresh = true
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english
    @State private var now = Date.now
    @State private var claudeAccessError: String?

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            UsageTheme.stage.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 18) {
                        header
                        UsageDetailedMetrics(
                            snapshots: store.snapshots,
                            now: now,
                            history: store.history,
                            language: language
                        )
                    }
                    .padding(20)
                    .usagePanel(cornerRadius: 16)

                    ConnectionSetupView(
                        statuses: store.connectionStatuses,
                        isRefreshing: store.isRefreshing,
                        errorMessage: claudeAccessError,
                        retry: {
                            Task { await store.refresh(force: true, allowInteraction: true) }
                        },
                        grantClaudeDesktopAccess: {
                            Task { await connectClaude() }
                        }
                    )

                    HStack {
                        Button(action: showSettings) {
                            Label(
                                language.text("Settings", "Ajustes"),
                                systemImage: "gearshape"
                            )
                        }
                        .buttonStyle(UsagePillButtonStyle())

                        Spacer()

                        Button {
                            openWindow(id: "floating")
                            dismissWindow(id: "dashboard")
                        } label: {
                            Label(
                                language.text("Floating window", "Ventana flotante"),
                                systemImage: "arrow.up.right.square"
                            )
                        }
                        .buttonStyle(UsagePillButtonStyle())
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 432)
        .frame(minHeight: 720)
        .onReceive(timer) { now = $0 }
        .onChange(of: store.snapshots) { _, _ in now = .now }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, store.requiresUserAction else { return }
            Task { await store.refresh(force: true, allowInteraction: false) }
        }
        .onChange(of: automaticRefresh) { _, enabled in
            store.setAutomaticPollingEnabled(enabled)
        }
        .task { store.setAutomaticPollingEnabled(automaticRefresh) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(UsagePillButtonStyle())
            .disabled(store.isRefreshing)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(now, style: .time)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UsageTheme.primaryText)
                UsageHeaderFreshnessLine(
                    snapshots: store.snapshots,
                    isRefreshing: store.isRefreshing,
                    now: now,
                    language: language
                )
            }
        }
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private func connectClaude() async {
        if ClaudeDesktopDataAccess.shared.hasUsableAccess {
            claudeAccessError = nil
            await store.refreshWhenIdle(force: true, allowInteraction: true)
            return
        }
        do {
            guard try await ClaudeDesktopAccessPicker.requestAccess() else { return }
            claudeAccessError = nil
            await store.refreshWhenIdle(force: true, allowInteraction: true)
        } catch {
            claudeAccessError = error.localizedDescription
        }
    }
}

struct UsageHeaderFreshnessLine: View {
    let snapshots: [ProviderUsageSnapshot]
    let isRefreshing: Bool
    let now: Date
    let language: AppLanguage

    var body: some View {
        if isRefreshing {
            Text(language.text("Updating…", "Actualizando…"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UsageTheme.mutedText)
        } else {
            let freshness = UsageFreshness(snapshots: snapshots, now: now)
            HStack(spacing: 4) {
                Text(statusText(freshness))
                    .foregroundStyle(
                        freshness.kind == .cached
                            ? UsageTheme.amber.opacity(0.72)
                            : UsageTheme.mutedText
                    )

                Image(systemName: freshness.kind == .cached ? "clock.fill" : "checkmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(
                        freshness.kind == .cached
                            ? UsageTheme.amber.opacity(0.72)
                            : UsageTheme.green.opacity(0.72)
                    )
            }
            .font(.system(size: 10.5, weight: .medium))
            .accessibilityElement(children: .combine)
        }
    }

    private func statusText(_ freshness: UsageFreshness) -> String {
        let label = freshness.kind == .cached
            ? language.text("Cached", "En caché")
            : language.text("Updated", "Actualizado")
        let time = freshness.date.formatted(date: .omitted, time: .shortened)
        return "\(label) \(time)"
    }
}
