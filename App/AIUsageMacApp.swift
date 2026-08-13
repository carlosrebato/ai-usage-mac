import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import AppKit
import Combine
import SwiftUI

private let menuBarLabelHeight: CGFloat = 19

@main
struct AIUsageMacApp: App {
    @NSApplicationDelegateAdaptor(AIUsageAppDelegate.self) private var appDelegate
    @AppStorage(AppPreferenceKey.onboardingCompleted) private var onboardingCompleted = false
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english

    var body: some Scene {
        Window(assistantWindowTitle, id: "onboarding") {
            OnboardingView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.assistantSetupContext)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(onboardingCompleted ? .suppressed : .presented)

        Window("AI Usage", id: "dashboard") {
            DashboardView()
                .environmentObject(appDelegate.store)
        }
        .defaultSize(width: 432, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("AI Usage HUD", id: "floating") {
            FloatingPanelView()
                .environmentObject(appDelegate.store)
        }
        .defaultSize(width: 256, height: 256)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.assistantSetupContext)
        }
        .windowResizability(.contentSize)
    }

    private var assistantWindowTitle: String {
        switch appDelegate.assistantSetupContext.mode {
        case .onboarding:
            language.text("Set up AI Usage", "Configura AI Usage")
        case .management:
            language.text("Manage AI assistants", "Gestionar asistentes de IA")
        }
    }
}

@MainActor
final class AIUsageAppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let assistantSetupContext = AssistantSetupContext()
    private var statusBarController: NativeStatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = NativeStatusBarController(
            store: store,
            assistantSetupContext: assistantSetupContext
        )
        runSmokeTestIfRequested()
    }

    private func runSmokeTestIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--smoke-test") else { return }
        let reportURL: URL = {
            guard let index = arguments.firstIndex(of: "--smoke-report"),
                  arguments.indices.contains(index + 1)
            else {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("ai-usage-smoke-report.json")
            }
            return URL(fileURLWithPath: arguments[index + 1])
        }()

        Task { @MainActor [store] in
            await store.refreshWhenIdle(force: true, allowInteraction: false)
            let providers: [[String: Any]] = UsageProviderID.allCases.map { provider in
                let snapshot = store.snapshots.first { $0.id == provider }
                let status = store.connectionStatuses.first { $0.id == provider }
                return [
                    "provider": provider.rawValue,
                    "connection": status.map { Self.smokePhase($0.phase) } ?? "missing",
                    "percent": snapshot?.highestPercent ?? NSNull(),
                    "source": snapshot?.source.rawValue ?? "missing",
                    "observedAt": snapshot?.observedAt.timeIntervalSince1970 ?? 0
                ]
            }
            let permissionsPersisted = providers.allSatisfy {
                guard let connection = $0["connection"] as? String else { return false }
                return !connection.hasPrefix("action-required") && connection != "missing"
            }
            let hasUsageData = providers.allSatisfy { !($0["percent"] is NSNull) }
            let passed = permissionsPersisted && hasUsageData
            let report: [String: Any] = [
                "passed": passed,
                "permissionsPersisted": permissionsPersisted,
                "hasUsageData": hasUsageData,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
                "providers": providers,
                "timestamp": Date.now.timeIntervalSince1970
            ]
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: report,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: reportURL, options: .atomic)
            } catch {
                fputs("AI Usage smoke report failed: \(error)\n", stderr)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private static func smokePhase(_ phase: ProviderConnectionPhase) -> String {
        switch phase {
        case .connected: "connected"
        case .checking: "checking"
        case .retrying: "retrying"
        case .actionRequired(let action): "action-required:\(action)"
        }
    }
}

@MainActor
private final class NativeStatusBarController: NSObject {
    private let store: UsageStore
    private let assistantSetupContext: AssistantSetupContext
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var minuteTimer: AnyCancellable?
    private var dashboardWindow: NSWindow?
    private var floatingWindow: NSPanel?
    private var settingsWindow: NSWindow?

    init(store: UsageStore, assistantSetupContext: AssistantSetupContext) {
        self.store = store
        self.assistantSetupContext = assistantSetupContext
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        observeChanges()
        applyAutomaticRefreshPreference()
        updateStatusItem()
#if DEBUG
        if CommandLine.arguments.contains("--verify-status-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showDashboard()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.showContextMenu()
                }
            }
        }
        if CommandLine.arguments.contains("--verify-status-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.togglePopover(relativeTo: button)
            }
        }
        if CommandLine.arguments.contains("--verify-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showSettings()
            }
        }
#endif
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
    }

    private func configurePopover() {
        let darkAppearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = darkAppearance
        popover.hasFullSizeContent = true
        popover.contentSize = NSSize(width: 392, height: 260)
        let hostingController = NSHostingController(
            rootView: MenuBarView(
                openDashboard: { [weak self] in self?.showDashboard() },
                detach: { [weak self] in self?.showFloatingWindow() },
                settings: { [weak self] in self?.showSettings() }
            )
            .environmentObject(store)
        )
        hostingController.view.appearance = darkAppearance
        popover.contentViewController = hostingController
    }

    private func observeChanges() {
        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyAutomaticRefreshPreference()
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        minuteTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateStatusItem() }
    }

    private func applyAutomaticRefreshPreference() {
        let enabled = UserDefaults.standard.object(
            forKey: AppPreferenceKey.automaticRefresh
        ) as? Bool ?? true
        store.setAutomaticPollingEnabled(enabled)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        popover.performClose(nil)
        let language = AppLanguage.current
        let menu = NSMenu()

        let resetItem = NSMenuItem(
            title: language.text("Show reset times", "Mostrar tiempos de reinicio"),
            action: #selector(toggleResetTimes(_:)),
            keyEquivalent: ""
        )
        resetItem.target = self
        resetItem.state = UserDefaults.standard.bool(
            forKey: AppPreferenceKey.showResetTimesInMenuBar
        ) ? .on : .off
        resetItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        menu.addItem(resetItem)

        let settingsItem = NSMenuItem(
            title: language.text("Settings…", "Ajustes…"),
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: language.text("Quit AI Usage", "Salir de AI Usage"),
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        guard let button = statusItem.button else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
    }

    @objc private func toggleResetTimes(_ sender: NSMenuItem) {
        let key = AppPreferenceKey.showResetTimesInMenuBar
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        updateStatusItem()
    }

    @objc private func openSettingsFromMenu(_ sender: NSMenuItem) {
        DispatchQueue.main.async { [weak self] in
            self?.showSettings()
        }
    }

    @objc private func quitApplication(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    private func showSettings() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            return
        }
        let controller = NSHostingController(
            rootView: SettingsView()
                .environmentObject(store)
                .environmentObject(assistantSetupContext)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = AppLanguage.current.text("AI Usage Settings", "Ajustes de AI Usage")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 668))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        settingsWindow = window
    }

    private func showDashboard() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(
            rootView: DashboardView().environmentObject(store)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "AI Usage"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 432, height: 760))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        dashboardWindow = window
    }

    private func showFloatingWindow() {
        popover.performClose(nil)
        if let floatingWindow {
            floatingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 256, height: 256),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(
            rootView: FloatingPanelView(onDock: { [weak self] in
                self?.floatingWindow?.orderOut(nil)
            })
            .environmentObject(store)
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        floatingWindow = panel
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let language = AppLanguage.current
        let showPercentage = UserDefaults.standard.object(
            forKey: AppPreferenceKey.showPercentageInMenuBar
        ) as? Bool ?? true
        let showResetTimes = UserDefaults.standard.bool(
            forKey: AppPreferenceKey.showResetTimesInMenuBar
        )
        let snapshots = UsageProviderID.allCases.compactMap { provider in
            store.snapshots.first {
                $0.id == provider && $0.menuBarPercent != nil
            }
        }

        guard showPercentage, !snapshots.isEmpty else {
            let image = NSImage(
                systemSymbolName: "chart.bar.fill",
                accessibilityDescription: "AI Usage"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = language.text("AI Usage has no data", "AI Usage sin datos")
            statusItem.length = NSStatusItem.squareLength
            return
        }

        let isDark = button.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let renderer = ImageRenderer(
            content: MenuBarUsageImageContent(
                snapshots: snapshots,
                colorScheme: isDark ? .dark : .light,
                showResetTimes: showResetTimes,
                now: .now
            )
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return }
        image.isTemplate = false
        button.image = image
        button.toolTip = accessibilityText(
            snapshots: snapshots,
            language: language,
            showResetTimes: showResetTimes
        )
        statusItem.length = image.size.width + 8
    }

    private func accessibilityText(
        snapshots: [ProviderUsageSnapshot],
        language: AppLanguage,
        showResetTimes: Bool
    ) -> String {
        snapshots.map { snapshot in
            let percent = snapshot.menuBarPercent.map { "\(Int($0.rounded()))%" } ?? "—"
            let reset = showResetTimes
                ? ", \(language.text("resets in", "se reinicia en")) \(resetText(snapshot))"
                : ""
            return "\(snapshot.id.displayName), \(percent) \(snapshot.menuBarPeriodDescription(language: language))\(reset)"
        }
        .joined(separator: "; ")
    }

    private func resetText(_ snapshot: ProviderUsageSnapshot) -> String {
        UsageResetFormatter.string(
            until: snapshot.primaryDisplayWindow.resetsAt,
            relativeTo: .now
        ).replacingOccurrences(of: " ", with: "")
    }
}

private struct MenuBarUsageLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    let snapshots: [AIUsageCore.ProviderUsageSnapshot]
    let language: AppLanguage
    let showResetTimes: Bool
    let now: Date

    var body: some View {
        if visibleSnapshots.isEmpty {
            Image(systemName: "chart.bar.fill")
                .accessibilityLabel(language.text("AI Usage has no data", "AI Usage sin datos"))
                .frame(width: menuBarLabelHeight, height: menuBarLabelHeight)
        } else if let renderedLabel {
            Image(nsImage: renderedLabel)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .frame(width: renderedLabel.size.width, height: menuBarLabelHeight)
                .fixedSize()
                .accessibilityLabel(accessibilityText)
        }
    }

    private var renderedLabel: NSImage? {
        let renderer = ImageRenderer(
            content: MenuBarUsageImageContent(
                snapshots: visibleSnapshots,
                colorScheme: colorScheme,
                showResetTimes: showResetTimes,
                now: now
            )
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    private var accessibilityText: String {
        visibleSnapshots.map { snapshot in
            let reset = showResetTimes
                ? ", \(language.text("resets in", "se reinicia en")) \(resetText(snapshot))"
                : ""
            return "\(snapshot.id.displayName), \(percent(snapshot.menuBarPercent)) \(snapshot.menuBarPeriodDescription(language: language))\(reset)"
        }.joined(separator: "; ")
    }

    private var visibleSnapshots: [AIUsageCore.ProviderUsageSnapshot] {
        AIUsageCore.UsageProviderID.allCases.compactMap { provider in
            snapshots.first { snapshot in
                snapshot.id == provider && snapshot.menuBarPercent != nil
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func resetText(_ snapshot: AIUsageCore.ProviderUsageSnapshot) -> String {
        AIUsageCore.UsageResetFormatter.string(
            until: snapshot.primaryDisplayWindow.resetsAt,
            relativeTo: now
        ).replacingOccurrences(of: " ", with: "")
    }
}

private struct MenuBarUsageImageContent: View {
    let snapshots: [AIUsageCore.ProviderUsageSnapshot]
    let colorScheme: ColorScheme
    let showResetTimes: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            ForEach(snapshots) { snapshot in
                HStack(spacing: 3) {
                    ProviderGlyph(
                        provider: snapshot.id,
                        size: iconSize(for: snapshot.id),
                        color: foregroundColor
                    )
                    Text(percent(snapshot.menuBarPercent))
                        .font(.system(size: 13.2, weight: .medium))
                        .foregroundStyle(foregroundColor)
                        .monospacedDigit()
                    if showResetTimes {
                        Text("|")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(foregroundColor.opacity(0.55))
                        Text(resetText(snapshot))
                            .font(.system(size: 13.2, weight: .medium))
                            .foregroundStyle(foregroundColor)
                            .monospacedDigit()
                        severityDot(snapshot)
                    } else {
                        severityDot(snapshot)
                    }
                }
            }
        }
        .frame(height: menuBarLabelHeight)
        .fixedSize(horizontal: true, vertical: true)
        .environment(\.colorScheme, colorScheme)
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func resetText(_ snapshot: AIUsageCore.ProviderUsageSnapshot) -> String {
        AIUsageCore.UsageResetFormatter.string(
            until: snapshot.primaryDisplayWindow.resetsAt,
            relativeTo: now
        ).replacingOccurrences(of: " ", with: "")
    }

    private func severityDot(_ snapshot: AIUsageCore.ProviderUsageSnapshot) -> some View {
        Circle()
            .fill(
                AIUsageDesignSystem.UsageTheme.severity(
                    AIUsageCore.UsageSeverity.forPercent(snapshot.menuBarPercent)
                )
            )
            .frame(width: 6, height: 6)
    }

    private func iconSize(for provider: AIUsageCore.UsageProviderID) -> CGFloat {
        switch provider {
        case .claude:
            13 * 1.10 * 1.10 * 1.20
        case .codex:
            13 * 1.05 * 1.20
        }
    }
}

private extension AIUsageCore.ProviderUsageSnapshot {
    var menuBarPercent: Double? {
        switch id {
        case .claude:
            session.usedPercent
        case .codex:
            weekly.usedPercent
        }
    }

    func menuBarPeriodDescription(language: AppLanguage) -> String {
        switch id {
        case .claude:
            language.text("in the 5-hour session", "en 5 horas")
        case .codex:
            language.text("for the week", "en la semana")
        }
    }
}
