import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import AIUsageProviderServices
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

struct SettingsView: View {
    private struct ProviderPresentation {
        let detail: String
        let badge: String
        let color: Color?
        let isConnected: Bool
        let isBusy: Bool
    }

    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var assistantSetupContext: AssistantSetupContext
    @EnvironmentObject private var providerSelection: ProviderSelectionStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppPreferenceKey.automaticRefresh) private var automaticRefresh = true
    @AppStorage(AppPreferenceKey.receiveBetaUpdates) private var receiveBetaUpdates = false
    @AppStorage(AppPreferenceKey.showPercentageInMenuBar) private var showPercentage = true
    @AppStorage(AppPreferenceKey.showResetTimesInMenuBar) private var showResetTimes = false
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @State private var tokenHistoryProvider: UsageProviderID?
    @State private var tokenHistoryErrors: [UsageProviderID: String] = [:]
    @State private var diagnosticExportError: String?

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            VStack(alignment: .leading, spacing: 24) {
                header
                assistantsSection

                settingsSection(language.text("General", "General")) {
                    preferenceRow(
                        systemName: "arrow.triangle.2.circlepath",
                        title: language.text("Automatic refresh", "Actualizar automáticamente"),
                        subtitle: language.text(
                            "Keeps your limits current in the background",
                            "Mantiene los límites al día en segundo plano"
                        ),
                        isOn: $automaticRefresh
                    )

                    settingsDivider

                    preferenceRow(
                        systemName: "menubar.rectangle",
                        title: language.text(
                            "Percentage in the menu bar",
                            "Porcentaje en la barra de menú"
                        ),
                        subtitle: language.text(
                            "Shows usage without opening the app",
                            "Muestra el uso sin abrir la aplicación"
                        ),
                        isOn: $showPercentage
                    )

                    settingsDivider

                    preferenceRow(
                        systemName: "timer",
                        title: language.text(
                            "Reset times in the menu bar",
                            "Tiempos de reinicio en la barra de menú"
                        ),
                        subtitle: language.text(
                            "Shows the countdown next to each percentage",
                            "Muestra la cuenta atrás junto a cada porcentaje"
                        ),
                        isOn: $showResetTimes
                    )
                    .disabled(!showPercentage)
                    .opacity(showPercentage ? 1 : 0.52)

                    settingsDivider
                    languageRow
                }

                launchSection
                privacyCallout
                diagnosticExport
                supportLinks
                footer
            }
            .padding(.top, 26)
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .frame(width: 560)
        .background(SettingsPalette.backgroundGradient)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowConfigurator(title: "AI Usage · Settings"))
        .preferredColorScheme(.dark)
        .environment(\.locale, language.locale)
        .onAppear {
            launchAtLogin.refresh()
            language.persistForExtensions()
        }
    }

    private var titleBar: some View {
        ZStack {
            Text("AI USAGE · SETTINGS")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.92)
                .foregroundStyle(SettingsPalette.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("AIUsageBrand")
                .resizable()
                .interpolation(.high)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage")
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.38)
                    .foregroundStyle(SettingsPalette.hero)

                Text(language.text(
                    "Preferences and local connections",
                    "Preferencias y conexiones locales"
                ))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SettingsPalette.secondary)
            }

            Spacer(minLength: 8)
        }
    }

    private var assistantsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel(language.text("Assistants", "Asistentes"))
                Spacer()
                SettingsLinkButton(title: language.text("Manage…", "Gestionar…")) {
                    assistantSetupContext.mode = .management
                    openWindow(id: "assistant-management")
                }
            }

            HStack(spacing: 10) {
                providerCard(.claude)
                providerCard(.codex)
            }
        }
    }

    private func providerCard(_ provider: UsageProviderID) -> some View {
        let presentation = providerPresentation(provider)

        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                ProviderGlyph(provider: provider, size: 17, color: SettingsPalette.glyph)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    }

                Spacer()

                if let color = presentation.color {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .shadow(color: color.opacity(0.55), radius: 5)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(provider == .claude ? "Claude" : "Codex")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(SettingsPalette.title)

                Text(providerMeta(presentation))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !presentation.isConnected {
                    HStack(spacing: 5) {
                        if presentation.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(SettingsPalette.accent)
                        } else {
                            Text(language.text("Connect", "Conectar"))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsPalette.accent)
                    .padding(.top, 4)
                }

                if presentation.isConnected && needsTokenHistoryAccess(provider) {
                    if tokenHistoryProvider == provider {
                        ProgressView()
                            .controlSize(.small)
                            .tint(SettingsPalette.accent)
                            .padding(.top, 5)
                    } else {
                        Button(language.text(
                            "Add token history",
                            "Añadir histórico de tokens"
                        )) {
                            Task { await addTokenHistory(for: provider) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPalette.accent)
                        .padding(.top, 5)
                    }
                }

                if let tokenHistoryError = tokenHistoryErrors[provider] {
                    Text(tokenHistoryError)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(UsageTheme.red)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.assistantGradient)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard !presentation.isConnected, !presentation.isBusy else { return }
            beginProviderSignIn(provider)
        }
        .accessibilityAction(named: language.text(
            "Connect \(provider.displayName)",
            "Conectar \(provider.displayName)"
        )) {
            guard !presentation.isConnected, !presentation.isBusy else { return }
            beginProviderSignIn(provider)
        }
        .accessibilityElement(children: .contain)
    }

    private func beginProviderSignIn(_ provider: UsageProviderID) {
        Task { @MainActor in
            _ = await store.connect(provider)
        }
    }

    private func needsTokenHistoryAccess(_ provider: UsageProviderID) -> Bool {
        !ProviderDataAccess.shared.hasUsableAccess(for: metricsDirectory(for: provider))
    }

    @MainActor
    private func addTokenHistory(for provider: UsageProviderID) async {
        tokenHistoryErrors[provider] = nil
        tokenHistoryProvider = provider
        defer { tokenHistoryProvider = nil }
        do {
            guard try await ProviderDataAccessPicker.requestAccess(for: provider) else { return }
            await store.refreshWhenIdle(force: true, allowInteraction: false)
        } catch {
            tokenHistoryErrors[provider] = error.localizedDescription
        }
    }

    private func metricsDirectory(for provider: UsageProviderID) -> ProviderDataDirectory {
        provider == .claude ? .claudeCode : .codex
    }

    private var launchSection: some View {
        settingsSection(language.text("Startup", "Inicio")) {
            HStack(spacing: 13) {
                settingsIcon("power")

                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("Open at login", "Abrir al iniciar sesión"))
                        .settingsRowTitle()
                    Text(launchAtLoginDetail)
                        .settingsRowSubtitle(
                            color: launchAtLogin.errorMessage == nil
                                ? SettingsPalette.secondary
                                : UsageTheme.red
                        )
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(SettingsToggleStyle())
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)

            if launchAtLogin.status == .requiresApproval {
                SettingsLinkButton(title: language.text(
                    "Confirm in System Settings",
                    "Confirmar en Ajustes del Sistema"
                )) {
                    launchAtLogin.openSystemSettings()
                }
                .padding(.leading, 58)
                .padding(.bottom, 12)
            }
        }
    }

    private var privacyCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsPalette.faint)
                .frame(width: 12, height: 12)
                .padding(.top, 2)

            Text(language.text(
                "Counters are processed locally with read-only access. AI Usage does not store or send the content of your conversations.",
                "Los contadores se procesan localmente y con acceso de solo lectura. AI Usage no almacena ni envía el contenido de tus conversaciones."
            ))
                .font(.system(size: 11.5, weight: .medium))
                .lineSpacing(5)
                .foregroundStyle(SettingsPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 3)
    }

    private var diagnosticExport: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsLinkButton(title: language.text(
                "Export diagnostics…",
                "Exportar diagnóstico…"
            )) {
                exportDiagnostics()
            }
            if let diagnosticExportError {
                Text(diagnosticExportError)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(UsageTheme.red)
            }
        }
    }

    private func exportDiagnostics() {
        diagnosticExportError = nil
        do {
            let data = try store.diagnosticReportData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "AI-Usage-Diagnostics.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            diagnosticExportError = error.localizedDescription
        }
    }

    private var supportLinks: some View {
        HStack(spacing: 16) {
            SettingsLinkButton(title: language.text("Help", "Ayuda")) {
                openSupportURL("https://github.com/carlosrebato/ai-usage-mac#readme")
            }
            SettingsLinkButton(title: language.text("Privacy", "Privacidad")) {
                openSupportURL("https://github.com/carlosrebato/ai-usage-mac/blob/main/PRIVACY.md")
            }
            SettingsLinkButton(title: language.text("Report an issue", "Informar de un problema")) {
                openSupportURL("https://github.com/carlosrebato/ai-usage-mac/issues/new/choose")
            }
        }
    }

    private func openSupportURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(language.text(
                "Estimated API equivalent · current reset period · USD",
                "Equivalente API estimado · periodo de reinicio actual · USD"
            ))
            + Text("   v\(appVersion)")

            Spacer(minLength: 10)

            Menu {
                Button(language.text("Check for Updates…", "Buscar actualizaciones…")) {
                    AppUpdater.shared.checkForUpdates()
                }

                Divider()

                Button {
                    selectUpdateChannel(beta: false)
                } label: {
                    if receiveBetaUpdates {
                        Text(language.text("Stable updates", "Actualizaciones estables"))
                    } else {
                        Label(language.text("Stable updates", "Actualizaciones estables"), systemImage: "checkmark")
                    }
                }

                Button {
                    selectUpdateChannel(beta: true)
                } label: {
                    if receiveBetaUpdates {
                        Label(language.text("Beta updates", "Actualizaciones beta"), systemImage: "checkmark")
                    } else {
                        Text(language.text("Beta updates", "Actualizaciones beta"))
                    }
                }
            } label: {
                Text(language.text("Updates…", "Actualizaciones…"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(SettingsPalette.accent)

            SettingsQuitButton(title: language.text("Quit AI Usage", "Salir de AI Usage")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(SettingsPalette.faint)
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)
        }
    }

    private func selectUpdateChannel(beta: Bool) {
        guard receiveBetaUpdates != beta else { return }
        receiveBetaUpdates = beta
        AppUpdater.shared.updateChannelSelection()
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(title)
            VStack(spacing: 0) { content() }
                .settingsCard()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased(with: language.locale))
            .font(.system(size: 11, weight: .bold))
            .tracking(1.76)
            .foregroundStyle(SettingsPalette.faint)
    }

    private func preferenceRow(
        systemName: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 13) {
            settingsIcon(systemName)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).settingsRowTitle()
                Text(subtitle).settingsRowSubtitle()
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SettingsToggleStyle())
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    private var languageRow: some View {
        HStack(spacing: 13) {
            settingsIcon("globe")

            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("Language", "Idioma")).settingsRowTitle()
                Text(language.text("Changes the entire app", "Cambia toda la aplicación"))
                    .settingsRowSubtitle()
            }

            Spacer()

            Menu {
                ForEach(AppLanguage.allCases) { option in
                    Button {
                        language = option
                        option.persistForExtensions()
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        if option == language {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(language.displayName)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SettingsPalette.secondary)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsPalette.buttonText)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color.white.opacity(0.04), in: Capsule())
                .overlay { Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(height: 1)
            .padding(.leading, 56)
    }

    private func settingsIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(SettingsPalette.icon)
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    private func providerPresentation(_ provider: UsageProviderID) -> ProviderPresentation {
        let status = store.connectionStatuses.first { $0.id == provider }
        let snapshot = store.snapshots.first { $0.id == provider }

        switch status?.phase {
        case .connected:
            let isCached = snapshot?.source == .cached
                || status?.dataState == .cached
                || status?.dataState == .stale
            return ProviderPresentation(
                detail: snapshot?.message ?? status?.message ?? language.text(
                    "Local session detected",
                    "Sesión local detectada"
                ),
                badge: isCached
                    ? language.text("Cached", "En caché")
                    : language.text("Connected", "Conectado"),
                color: isCached ? UsageTheme.cached : SettingsPalette.accent,
                isConnected: true,
                isBusy: false
            )
        case .checking:
            return ProviderPresentation(
                detail: status?.message ?? language.text(
                    "Checking the connection…",
                    "Comprobando la conexión…"
                ),
                badge: language.text("Checking", "Comprobando"),
                color: UsageTheme.amber,
                isConnected: false,
                isBusy: true
            )
        case .actionRequired:
            let notice = status?.notice ?? .none
            let color: Color? = switch notice {
            case .none: nil
            case .attention: UsageTheme.amber
            case .error: UsageTheme.red
            }
            return ProviderPresentation(
                detail: status?.message(in: language) ?? language.text("Setup required", "Necesita configuración"),
                badge: notice == .none
                    ? language.text("Not connected", "Sin conectar")
                    : language.text("Attention", "Atención"),
                color: color,
                isConnected: false,
                isBusy: false
            )
        case .retrying:
            return ProviderPresentation(
                detail: status?.message ?? language.text("Could not connect", "No se pudo conectar"),
                badge: language.text("Retrying", "Reintentando"),
                color: UsageTheme.red,
                isConnected: false,
                isBusy: false
            )
        case .none:
            return ProviderPresentation(
                detail: snapshot?.message ?? language.text("No data", "Sin datos"),
                badge: language.text("Not connected", "Sin conectar"),
                color: nil,
                isConnected: false,
                isBusy: false
            )
        }
    }

    private func providerMeta(_ presentation: ProviderPresentation) -> String {
        let detail = presentation.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if presentation.isConnected {
            guard detail.hasPrefix("Plan ") else { return presentation.badge }
            let plan = String(detail.dropFirst(5))
            return "\(plan) · \(presentation.badge)"
        }
        return detail
    }

    private var launchAtLoginDetail: String {
        if let error = launchAtLogin.errorMessage {
            return "\(language.text("Could not change this setting", "No se pudo cambiar")): \(error)"
        }
        return switch launchAtLogin.status {
        case .enabled:
            language.text("AI Usage will open automatically", "AI Usage se abrirá automáticamente")
        case .requiresApproval:
            language.text("Confirm it in System Settings", "Falta confirmarlo en Ajustes del Sistema")
        case .disabled:
            language.text("You can change this at any time", "Puedes cambiarlo en cualquier momento")
        case .unavailable:
            language.text("Enable it to register with macOS", "Actívalo para registrarlo con macOS")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

enum SettingsPalette {
    static let hero = Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255)
    static let title = Color(red: 244 / 255, green: 244 / 255, blue: 246 / 255)
    static let buttonText = Color(red: 216 / 255, green: 216 / 255, blue: 220 / 255)
    static let icon = Color(red: 194 / 255, green: 196 / 255, blue: 202 / 255)
    static let glyph = Color(red: 232 / 255, green: 232 / 255, blue: 234 / 255)
    static let secondary = Color(red: 144 / 255, green: 146 / 255, blue: 154 / 255)
    static let faint = Color(red: 134 / 255, green: 136 / 255, blue: 144 / 255)
    static let accent = Color(red: 62 / 255, green: 207 / 255, blue: 142 / 255)

    static let backgroundGradient = RadialGradient(
        colors: [
            Color(red: 13 / 255, green: 14 / 255, blue: 16 / 255),
            Color(red: 7 / 255, green: 7 / 255, blue: 8 / 255)
        ],
        center: UnitPoint(x: 0.5, y: -0.1),
        startRadius: 0,
        endRadius: 690
    )

    static let assistantGradient = RadialGradient(
        colors: [accent.opacity(0.09), Color.white.opacity(0.03)],
        center: UnitPoint(x: 0.5, y: -0.2),
        startRadius: 0,
        endRadius: 210
    )
}

private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? SettingsPalette.accent : Color.white.opacity(0.12))
                    .shadow(
                        color: configuration.isOn ? SettingsPalette.accent.opacity(0.45) : .clear,
                        radius: 6
                    )

                Circle()
                    .fill(SettingsPalette.title)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .padding(2.5)
            }
            .frame(width: 40, height: 23)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct SettingsLinkButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isHovering ? Color(red: 106 / 255, green: 223 / 255, blue: 169 / 255) : SettingsPalette.accent)
            .onHover { isHovering = $0 }
    }
}

private struct SettingsQuitButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SettingsPalette.buttonText)
            .padding(.horizontal, 15)
            .frame(height: 30)
            .background(Color.white.opacity(isHovering ? 0.08 : 0.04), in: Capsule())
            .overlay {
                Capsule().stroke(Color.white.opacity(isHovering ? 0.14 : 0.08), lineWidth: 1)
            }
            .onHover { isHovering = $0 }
    }
}

struct SettingsWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = NSColor(
            calibratedRed: 9 / 255,
            green: 10 / 255,
            blue: 12 / 255,
            alpha: 1
        )
        window.isOpaque = true
        window.isMovableByWindowBackground = true
        window.hasShadow = true
    }
}

private extension View {
    func settingsCard() -> some View {
        background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    func settingsRowTitle() -> some View {
        font(.system(size: 13.5, weight: .semibold))
            .tracking(-0.07)
            .foregroundStyle(SettingsPalette.title)
    }

    func settingsRowSubtitle(color: Color = SettingsPalette.secondary) -> some View {
        font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
