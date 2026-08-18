import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import AppKit
import SwiftUI

struct MenuBarView: View {
    private enum Layout {
        static let width: CGFloat = 392
    }

    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var providerSelection: ProviderSelectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppPreferenceKey.automaticRefresh) private var automaticRefresh = true
    @AppStorage(AppPreferenceKey.showResetTimesInMenuBar) private var showResetTimes = false
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english
    @State private var isExpanded = false
    @State private var now = Date.now

    private let detachAction: (() -> Void)?
    private let settingsAction: (() -> Void)?

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init(
        detach: (() -> Void)? = nil,
        settings: (() -> Void)? = nil
    ) {
        detachAction = detach
        settingsAction = settings
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 16)

                UsageDetailedMetrics(
                    snapshots: visibleSnapshots,
                    now: now,
                    history: store.history,
                    language: language
                )
                    .environment(\.locale, language.locale)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            } else {
                UsageCompactMetrics(
                    snapshots: visibleSnapshots,
                    now: now,
                    language: language
                )
                    .padding(.vertical, 16)
            }

            Rectangle().fill(UsageTheme.hairline).frame(height: 1)
            controls
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .frame(width: Layout.width)
        .fixedSize(horizontal: true, vertical: true)
        .id(isExpanded ? "expanded" : "compact")
        .background(UsageTheme.panelGradient)
        .animation(nil, value: isExpanded)
        .onReceive(timer) { now = $0 }
        .onChange(of: store.snapshots) { _, _ in now = .now }
        .onChange(of: automaticRefresh) { _, enabled in
            store.setAutomaticPollingEnabled(enabled)
        }
        .task { store.setAutomaticPollingEnabled(automaticRefresh) }
    }

    private var expandedHeader: some View {
        HStack(alignment: .top) {
            Text("AI USAGE")
                .font(.system(size: 13, weight: .bold))
                .tracking(2.35)
                .foregroundStyle(UsageTheme.tertiaryText)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(now, style: .time)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UsageTheme.primaryText)
                UsageHeaderFreshnessLine(
                    snapshots: visibleSnapshots,
                    isRefreshing: store.isRefreshing,
                    now: now,
                    language: language
                )
            }
        }
    }

    private var visibleSnapshots: [ProviderUsageSnapshot] {
        providerSelection.filtering(store.snapshots)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                Label(
                    isExpanded
                        ? language.text("Collapse", "Contraer")
                        : language.text("Expand", "Expandir"),
                    systemImage: isExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(UsagePillButtonStyle())

            Button(action: popOut) {
                Label(
                    language.text("Detach", "Separar"),
                    systemImage: "arrow.up.right.square"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(UsagePillButtonStyle())

            Button(action: showSettings) {
                Label(
                    language.text("Settings", "Ajustes"),
                    systemImage: "gearshape"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(UsagePillButtonStyle())

        }
    }

    private func popOut() {
        if let detachAction {
            detachAction()
            return
        }
        let menuWindow = NSApp.keyWindow
        openWindow(id: "floating")
        dismiss()
        DispatchQueue.main.async {
            menuWindow?.orderOut(nil)
        }
    }

    private func showSettings() {
        if let settingsAction {
            settingsAction()
            return
        }
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            openSettings()
        }
    }
}
