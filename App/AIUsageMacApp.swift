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
                .environmentObject(appDelegate.providerSelection)
        }
        .defaultSize(width: 520, height: 590)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(shouldPresentOnboarding ? .presented : .suppressed)

        Window("Manage AI assistants", id: "assistant-management") {
            OnboardingView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.assistantSetupContext)
                .environmentObject(appDelegate.providerSelection)
        }
        .defaultSize(width: 520, height: 440)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("AI Usage HUD", id: "floating") {
            FloatingPanelView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.providerSelection)
        }
        .defaultSize(width: FloatingPanelView.size.width, height: FloatingPanelView.size.height)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.assistantSetupContext)
                .environmentObject(appDelegate.providerSelection)
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

    private var shouldPresentOnboarding: Bool {
#if DEBUG
        if CommandLine.arguments.contains("--verify-status-popover")
            || CommandLine.arguments.contains("--verify-claude-metrics-picker") {
            return false
        }
#endif
        return !onboardingCompleted
            || !appDelegate.providerSelection.hasActiveProvider
    }
}

@MainActor
final class AIUsageAppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let assistantSetupContext = AssistantSetupContext()
    let providerSelection = ProviderSelectionStore()
    private let updater = AppUpdater.shared
    private var statusBarController: NativeStatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = NativeStatusBarController(
            store: store,
            assistantSetupContext: assistantSetupContext,
            providerSelection: providerSelection
        )
        runKeychainSmokeTestIfRequested()
        runSmokeTestIfRequested()
    }

    private func runKeychainSmokeTestIfRequested() {
        guard CommandLine.arguments.contains("--verify-oauth-keychain") else { return }
        let result: [String: Any]
        do {
            try ClaudeAccountOAuth.verifyKeychainAccess()
            result = ["keychainAccess": true]
        } catch {
            result = ["keychainAccess": false, "error": error.localizedDescription]
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        NSApplication.shared.terminate(nil)
    }

    private func runSmokeTestIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--smoke-test") else { return }
        let reportURL: URL? = {
            guard let index = arguments.firstIndex(of: "--smoke-report"),
                  arguments.indices.contains(index + 1)
            else { return nil }
            return URL(fileURLWithPath: arguments[index + 1])
        }()

        Task { @MainActor [store] in
            await store.refreshWhenIdle(force: true, allowInteraction: false)
            let enabledProviders = Array(providerSelection.activeProviders)
            let providers: [[String: Any]] = enabledProviders.map { provider in
                let snapshot = store.snapshots.first { $0.id == provider }
                let status = store.connectionStatuses.first { $0.id == provider }
                return [
                    "provider": provider.rawValue,
                    "connection": status.map { Self.smokePhase($0.phase) } ?? "missing",
                    "message": status?.message ?? snapshot?.message ?? "missing",
                    "percent": snapshot?.highestPercent ?? NSNull(),
                    "source": snapshot?.source.rawValue ?? "missing",
                    "observedAt": snapshot?.observedAt.timeIntervalSince1970 ?? 0
                ]
            }
            let permissionsPersisted = !enabledProviders.isEmpty && enabledProviders.allSatisfy { provider in
                if ProviderDataAccess.shared.hasUsableAccess(
                    for: provider == .claude ? .claude : .codex
                ) {
                    return true
                }
                let snapshot = store.snapshots.first { $0.id == provider }
                let status = store.connectionStatuses.first { $0.id == provider }
                guard snapshot?.highestPercent != nil else { return false }
                return status?.phase == .connected || status?.phase == .retrying
            }
            let hasUsageData = providers.allSatisfy { !($0["percent"] is NSNull) }
            let hasLiveData = providers.allSatisfy {
                $0["source"] as? String == UsageSource.live.rawValue
            }
            let passed = permissionsPersisted && hasUsageData && hasLiveData
            let report: [String: Any] = [
                "passed": passed,
                "permissionsPersisted": permissionsPersisted,
                "hasUsageData": hasUsageData,
                "hasLiveData": hasLiveData,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
                "providers": providers,
                "timestamp": Date.now.timeIntervalSince1970
            ]
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: report,
                    options: [.prettyPrinted, .sortedKeys]
                )
                if let reportURL {
                    try data.write(to: reportURL, options: .atomic)
                } else {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
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
private final class NativeStatusBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let assistantSetupContext: AssistantSetupContext
    private let providerSelection: ProviderSelectionStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var minuteTimer: AnyCancellable?
    private var floatingWindow: NSPanel?
    private var settingsWindow: NSWindow?
    private var localDismissMonitor: Any?
    private var globalDismissMonitor: Any?

    init(
        store: UsageStore,
        assistantSetupContext: AssistantSetupContext,
        providerSelection: ProviderSelectionStore
    ) {
        self.store = store
        self.assistantSetupContext = assistantSetupContext
        self.providerSelection = providerSelection
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        observeChanges()
        applyAutomaticRefreshPreference()
        updateStatusItem()
#if DEBUG
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
        if CommandLine.arguments.contains("--verify-claude-metrics-picker") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Task { _ = try? await ClaudeCodeMetricsAccessPicker.requestAccess() }
            }
        }
        if CommandLine.arguments.contains("--verify-detach") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showFloatingWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    let isVisible = self?.floatingWindow?.isVisible == true
                    fputs("AI Usage detach visible: \(isVisible)\n", stderr)
                    if let reportIndex = CommandLine.arguments.firstIndex(
                        of: "--verify-detach-report"
                    ), CommandLine.arguments.indices.contains(reportIndex + 1) {
                        let reportURL = URL(
                            fileURLWithPath: CommandLine.arguments[reportIndex + 1]
                        )
                        try? "visible=\(isVisible)\n".write(
                            to: reportURL,
                            atomically: true,
                            encoding: .utf8
                        )
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
#endif
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // Handle the press before a transient popover auto-closes on mouse-up.
        // Otherwise the same click can immediately reopen it and appear ignored.
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
    }

    private func configurePopover() {
        let darkAppearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.appearance = darkAppearance
        popover.hasFullSizeContent = true
        popover.contentSize = NSSize(width: 392, height: 260)
        let hostingController = NSHostingController(
            rootView: MenuBarView(
                detach: { [weak self] in self?.showFloatingWindow() },
                settings: { [weak self] in self?.showSettings() }
            )
            .environmentObject(store)
            .environmentObject(providerSelection)
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

        providerSelection.$activeProviders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
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
        if NSApp.currentEvent?.type == .rightMouseDown {
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
            installPopoverDismissMonitors()
        }
    }

    private func installPopoverDismissMonitors() {
        removePopoverDismissMonitors()
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            guard let self, self.popover.isShown else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            let statusWindow = self.statusItem.button?.window
            guard event.window !== popoverWindow, event.window !== statusWindow else {
                return event
            }
            self.popover.performClose(nil)
            return event
        }
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }
    }

    private func removePopoverDismissMonitors() {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverDismissMonitors()
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
                .environmentObject(providerSelection)
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

    private func showFloatingWindow() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let floatingWindow {
            presentFloatingWindow(floatingWindow)
            return
        }

        let panel = AIUsageFloatingPanel(
            contentRect: NSRect(origin: .zero, size: FloatingPanelView.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(
            rootView: FloatingPanelView(onDock: { [weak self] in
                self?.floatingWindow?.orderOut(nil)
            })
            .environmentObject(store)
            .environmentObject(providerSelection)
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.center()
        floatingWindow = panel
        presentFloatingWindow(panel)
    }

    private func presentFloatingWindow(_ panel: NSPanel) {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
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
        let snapshots = UsageProviderID.allCases
            .filter(providerSelection.isActive)
            .compactMap { provider in
            store.snapshots.first {
                $0.id == provider && $0.menuBarPercent != nil
            }
            }

        guard showPercentage, !snapshots.isEmpty else {
            let image = (NSImage(named: "AIUsageBrand")
                ?? NSApplication.shared.applicationIconImage)?.copy() as? NSImage
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = false
            button.image = image
            button.toolTip = snapshots.isEmpty
                ? language.text("AI Usage has no data", "AI Usage sin datos")
                : "AI Usage"
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

private final class AIUsageFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
