import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import SwiftUI

struct OnboardingView: View {
    private enum ProviderIndicator: Equatable {
        case none
        case connected
        case attention
        case error
        case information
        case busy
    }

    private struct CardState {
        let title: String
        let subtitle: String
        let indicator: ProviderIndicator
        let actionTitle: String?
        let actionIsQuiet: Bool
    }

    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var assistantSetupContext: AssistantSetupContext
    @EnvironmentObject private var providerSelection: ProviderSelectionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppPreferenceKey.onboardingCompleted) private var onboardingCompleted = false
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @State private var busyProvider: UsageProviderID?
    @State private var accessError: String?

    var body: some View {
        Group {
            if isOnboarding {
                onboardingContent
            } else {
                managementContent
            }
        }
        .environment(\.locale, language.locale)
        .task {
            launchAtLogin.refresh()
            await store.refresh(force: true, allowInteraction: false)
        }
    }

    private var onboardingContent: some View {
        VStack(spacing: 0) {
            managementTitleBar

            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text(headerTitle)
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(SettingsPalette.hero)

                    Text(headerSubtitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SettingsPalette.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .frame(maxWidth: 410)
                }

                VStack(spacing: 10) {
                    managementProviderCard(.claude)
                    managementProviderCard(.codex)
                }

                if let accessError {
                    Text(accessError)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(UsageTheme.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPalette.faint)
                    Text(language.text(
                        "Granted access is always read-only.",
                        "El acceso concedido es siempre de solo lectura."
                    ))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SettingsPalette.secondary)
                }

                onboardingLaunchRow

                HStack(spacing: 8) {
                    if !canStart {
                        Text(language.text(
                            "Connect at least one assistant to get started",
                            "Conecta al menos un asistente para empezar"
                        ))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SettingsPalette.secondary)
                    }
                    Spacer()
                    ManagementGhostButton(title: language.text("Not now", "Ahora no")) {
                        finish()
                    }
                    ManagementPrimaryButton(title: language.text("Get started", "Empezar")) {
                        finish()
                    }
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.42)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                }
            }
            .padding(.top, 30)
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .frame(width: 520)
        .background(SettingsPalette.backgroundGradient)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .overlay(alignment: .top) {
            Text(language.text("SET UP AI USAGE", "CONFIGURAR AI USAGE"))
                .font(.system(size: 12, weight: .bold))
                .tracking(1.92)
                .foregroundStyle(SettingsPalette.secondary)
                .frame(height: 44)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowConfigurator(title: windowTitle))
        .preferredColorScheme(.dark)
    }

    private var onboardingLaunchRow: some View {
        HStack(spacing: 13) {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsPalette.icon)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("Open at login", "Abrir al iniciar sesión"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(SettingsPalette.title)
                Text(language.text(
                    "AI Usage will open automatically",
                    "AI Usage se abrirá automáticamente"
                ))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsPalette.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(SettingsPalette.accent)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var managementContent: some View {
        VStack(spacing: 0) {
            managementTitleBar

            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text(language.text(
                        "Manage your AI assistants",
                        "Gestiona tus asistentes de IA"
                    ))
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(SettingsPalette.hero)

                    Text(headerSubtitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SettingsPalette.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .frame(maxWidth: 400)
                }
                .padding(.horizontal, 20)

                VStack(spacing: 10) {
                    managementProviderCard(.claude)
                    managementProviderCard(.codex)
                }

                if let accessError {
                    Text(accessError)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(UsageTheme.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPalette.faint)

                    Text(language.text(
                        "Granted access is always read-only.",
                        "El acceso concedido es siempre de solo lectura."
                    ))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SettingsPalette.secondary)
                }
                .accessibilityElement(children: .combine)

                HStack {
                    Spacer()
                    ManagementPrimaryButton(title: language.text("Done", "Listo")) {
                        dismissWindow(id: "assistant-management")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1)
                }
            }
            .padding(.top, 30)
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .frame(width: 520, height: 440)
        .background(SettingsPalette.backgroundGradient)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .overlay(alignment: .top) {
            Text(language.text("MANAGE AI ASSISTANTS", "GESTIONAR ASISTENTES DE IA"))
                .font(.system(size: 12, weight: .bold))
                .tracking(1.92)
                .foregroundStyle(SettingsPalette.secondary)
                .frame(height: 44)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowConfigurator(title: windowTitle))
        .preferredColorScheme(.dark)
    }

    private var managementTitleBar: some View {
        Color.clear
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

    private func managementProviderCard(_ provider: UsageProviderID) -> some View {
        let state = cardState(for: provider)
        let connected = state.indicator == .connected
        let needsClaudeTokenAccess = provider == .claude
            && ProviderDataAccess.shared.hasStoredAccess(for: .claude)
            && !ProviderDataAccess.shared.hasUsableAccess(for: .claudeCode)
        let actionTitle = needsClaudeTokenAccess
            ? language.text("Add token history", "Añadir histórico de tokens")
            : state.actionTitle

        return HStack(spacing: 14) {
            ProviderGlyph(provider: provider, size: 18, color: SettingsPalette.glyph)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    managementIndicator(state.indicator)

                    Text(state.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(SettingsPalette.title)
                        .lineLimit(1)
                }

                Text(state.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, state.indicator == .busy ? 0 : 15)
            }

            Spacer(minLength: 8)

            if state.indicator == .busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(SettingsPalette.accent)
            } else {
                HStack(spacing: 8) {
                    if connected {
                        ManagementVisibilityButton(
                            isVisible: isProviderVisible(provider),
                            language: language
                        ) {
                            setProviderVisible(!isProviderVisible(provider), provider: provider)
                        }
                    }

                    if let actionTitle {
                        ManagementGhostButton(title: actionTitle) {
                            if needsClaudeTokenAccess {
                                Task { await connectClaudeTokenHistory() }
                            } else {
                                performAction(for: provider)
                            }
                        }
                    }
                }
                .disabled(busyProvider != nil)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 16)
        .background {
            if connected {
                SettingsPalette.assistantGradient
            } else {
                Color.white.opacity(0.03)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.displayName), \(state.title), \(state.subtitle)")
    }

    @ViewBuilder
    private func managementIndicator(_ indicator: ProviderIndicator) -> some View {
        switch indicator {
        case .busy:
            EmptyView()
        case .connected:
            Circle()
                .fill(SettingsPalette.accent)
                .frame(width: 7, height: 7)
                .shadow(color: SettingsPalette.accent.opacity(0.55), radius: 5)
        case .attention:
            Circle()
                .fill(UsageTheme.amber)
                .frame(width: 7, height: 7)
                .shadow(color: UsageTheme.amber.opacity(0.45), radius: 4)
        case .error:
            Circle()
                .fill(UsageTheme.red)
                .frame(width: 7, height: 7)
                .shadow(color: UsageTheme.red.opacity(0.45), radius: 4)
        case .none, .information:
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
        }
    }

    private var isOnboarding: Bool {
        assistantSetupContext.mode == .onboarding
    }

    private var headerTitle: String {
        isOnboarding
            ? language.text("Connect your AI assistants", "Conecta tus asistentes de IA")
            : language.text("Manage your AI assistants", "Gestiona tus asistentes de IA")
    }

    private var windowTitle: String {
        isOnboarding
            ? language.text("Set up AI Usage", "Configura AI Usage")
            : language.text("Manage AI assistants", "Gestionar asistentes de IA")
    }

    private var headerSubtitle: String {
        isOnboarding
            ? language.text(
                "Check your usage limits from the menu bar. AI Usage processes counters locally and does not analyze, store, or send the content of your conversations.",
                "Consulta tus límites de uso desde la barra de menú. AI Usage procesa localmente los contadores y no analiza, almacena ni envía el contenido de tus conversaciones."
            )
            : language.text(
                "Review or update the local connections AI Usage uses to read your usage counters.",
                "Revisa o actualiza las conexiones locales que AI Usage usa para leer tus contadores de uso."
            )
    }

    private func providerCard(_ provider: UsageProviderID) -> some View {
        let state = cardState(for: provider)

        return HStack(spacing: 13) {
            ProviderGlyph(provider: provider, size: 19, color: primaryText)
                .frame(width: 34, height: 34)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(cardBorder, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    indicator(state.indicator)
                    Text(state.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(primaryText)
                }

                Text(state.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if state.indicator == .busy {
                ProgressView().controlSize(.small)
            } else if let actionTitle = state.actionTitle {
                actionButton(
                    title: actionTitle,
                    isQuiet: state.actionIsQuiet,
                    provider: provider
                )
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        }
        .accessibilityLabel("\(provider.displayName), \(state.title), \(state.subtitle)")
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        isQuiet: Bool,
        provider: UsageProviderID
    ) -> some View {
        if isQuiet {
            Button(title) { performAction(for: provider) }
                .buttonStyle(.plain)
                .foregroundStyle(secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
                .disabled(busyProvider != nil)
        } else {
            Button(title) { performAction(for: provider) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(actionColor)
                .disabled(busyProvider != nil)
        }
    }

    @ViewBuilder
    private func indicator(_ indicator: ProviderIndicator) -> some View {
        switch indicator {
        case .none, .busy:
            EmptyView()
        case .connected:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(connectedColor)
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(attentionColor)
        case .error:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(errorColor)
        case .information:
            Image(systemName: "info.circle").foregroundStyle(tertiaryText)
        }
    }

    private func cardState(for provider: UsageProviderID) -> CardState {
        if busyProvider == provider {
            return CardState(
                title: provider == .claude
                    ? language.text("Connecting…", "Conectando…")
                    : language.text("Checking…", "Comprobando…"),
                subtitle: provider == .claude
                    ? language.text(
                        "Checking the authorized Claude data folder.",
                        "Comprobando la carpeta de datos autorizada de Claude."
                    )
                    : language.text(
                        "Checking the authorized .codex folder.",
                        "Comprobando la carpeta .codex autorizada."
                    ),
                indicator: .busy,
                actionTitle: nil,
                actionIsQuiet: false
            )
        }

        guard let status = store.connectionStatuses.first(where: { $0.id == provider }) else {
            return initialState(for: provider)
        }

        switch status.phase {
        case .connected:
            let message = store.snapshots.first(where: { $0.id == provider })?.message
            return CardState(
                title: "\(provider == .claude ? "Claude" : "Codex") \(language.text("connected", "conectado"))",
                subtitle: message ?? language.text("Local session detected", "Sesión local detectada"),
                indicator: .connected,
                actionTitle: language.text("Change access", "Cambiar acceso"),
                actionIsQuiet: true
            )
        case .checking:
            return initialState(for: provider)
        case .retrying:
            return CardState(
                title: language.text("Could not connect", "No se pudo conectar"),
                subtitle: status.message,
                indicator: .error,
                actionTitle: language.text("Retry", "Reintentar"),
                actionIsQuiet: false
            )
        case .actionRequired(let action):
            return actionState(action, provider: provider, message: status.message)
        }
    }

    private func actionState(
        _ action: ProviderSetupAction,
        provider: UsageProviderID,
        message: String
    ) -> CardState {
        switch action {
        case .grantPermission:
            return CardState(
                title: language.text(
                    "Choose the \(dataDirectory(for: provider).folderName) folder",
                    "Elige la carpeta \(dataDirectory(for: provider).folderName)"
                ),
                subtitle: message,
                indicator: .attention,
                actionTitle: language.text("Connect", "Conectar"),
                actionIsQuiet: false
            )
        case .signIn:
            return CardState(
                title: language.text("Sign in to continue", "Inicia sesión para continuar"),
                subtitle: message,
                indicator: .attention,
                actionTitle: "\(language.text("Open", "Abrir")) \(provider == .claude ? "Claude" : "Codex")",
                actionIsQuiet: false
            )
        case .install:
            return CardState(
                title: "\(provider == .claude ? "Claude" : "Codex") \(language.text("is not installed", "no está instalado"))",
                subtitle: message,
                indicator: .information,
                actionTitle: language.text("Install", "Instalar"),
                actionIsQuiet: false
            )
        case .retry:
            return CardState(
                title: language.text("Could not connect", "No se pudo conectar"),
                subtitle: message,
                indicator: .error,
                actionTitle: language.text("Retry", "Reintentar"),
                actionIsQuiet: false
            )
        }
    }

    private func initialState(for provider: UsageProviderID) -> CardState {
        CardState(
            title: provider == .claude ? "Claude" : "Codex",
            subtitle: provider == .claude
                ? language.text(
                    "Choose your .claude folder once to read your Claude Code session and counters.",
                    "Elige una vez tu carpeta .claude para leer la sesión y contadores de Claude Code."
                )
                : language.text(
                    "Choose .codex once to read your local session and counters.",
                    "Elige .codex una vez para leer tu sesión y contadores locales."
                ),
            indicator: .none,
            actionTitle: language.text("Connect", "Conectar"),
            actionIsQuiet: false
        )
    }

    private func performAction(for provider: UsageProviderID) {
        accessError = nil
        let status = store.connectionStatuses.first { $0.id == provider }

        if status?.phase == .connected || status?.action == .grantPermission {
            Task { await connect(provider) }
            return
        }
        if status?.phase == .checking {
            Task { await connect(provider) }
            return
        }

        if let action = status?.action {
            switch action {
            case .signIn:
                ProviderAppLauncher.open(provider, installationFallback: false)
                return
            case .install:
                ProviderAppLauncher.open(provider, installationFallback: true)
                return
            case .grantPermission, .retry:
                break
            }
        }

        Task { await refresh(provider) }
    }

    private func connect(_ provider: UsageProviderID) async {
        do {
            guard try await ProviderDataAccessPicker.requestAccess(for: provider) else { return }
            setProviderVisible(true, provider: provider)
            await refresh(provider)
        } catch {
            accessError = error.localizedDescription
        }
    }

    private func connectClaudeTokenHistory() async {
        accessError = nil
        busyProvider = .claude
        defer { busyProvider = nil }
        do {
            guard try await ClaudeCodeMetricsAccessPicker.requestAccess() else { return }
            await store.refreshWhenIdle(force: true, allowInteraction: false)
        } catch {
            accessError = error.localizedDescription
        }
    }

    private func dataDirectory(for provider: UsageProviderID) -> ProviderDataDirectory {
        provider == .claude ? .claude : .codex
    }

    private func refresh(_ provider: UsageProviderID) async {
        busyProvider = provider
        defer { busyProvider = nil }
        await store.refreshWhenIdle(force: true, allowInteraction: true)
    }

    private var canStart: Bool {
        store.connectionStatuses.contains { status in
            status.isConnected && isProviderVisible(status.id)
        }
    }

    private func isProviderVisible(_ provider: UsageProviderID) -> Bool {
        providerSelection.isActive(provider)
    }

    private func setProviderVisible(_ visible: Bool, provider: UsageProviderID) {
        providerSelection.setActive(visible, for: provider)
    }

    private func finish() {
        onboardingCompleted = true
        dismissWindow(id: "onboarding")
    }

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255)
            : Color(red: 247 / 255, green: 247 / 255, blue: 249 / 255)
    }

    private var cardBackground: Color {
        colorScheme == .dark ? .white.opacity(0.045) : .black.opacity(0.04)
    }

    private var cardBorder: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.09)
    }

    private var primaryText: Color {
        colorScheme == .dark
            ? Color(red: 244 / 255, green: 244 / 255, blue: 246 / 255)
            : Color(red: 26 / 255, green: 27 / 255, blue: 32 / 255)
    }

    private var secondaryText: Color {
        colorScheme == .dark
            ? Color(red: 154 / 255, green: 156 / 255, blue: 162 / 255)
            : Color(red: 99 / 255, green: 101 / 255, blue: 108 / 255)
    }

    private var tertiaryText: Color {
        colorScheme == .dark
            ? Color(red: 124 / 255, green: 126 / 255, blue: 134 / 255)
            : Color(red: 112 / 255, green: 114 / 255, blue: 121 / 255)
    }

    private let actionColor = Color(red: 64 / 255, green: 115 / 255, blue: 1)
    private var connectedColor: Color {
        colorScheme == .dark
            ? UsageTheme.green
            : Color(red: 20 / 255, green: 154 / 255, blue: 102 / 255)
    }
    private var attentionColor: Color {
        colorScheme == .dark
            ? UsageTheme.amber
            : Color(red: 209 / 255, green: 138 / 255, blue: 6 / 255)
    }
    private var errorColor: Color {
        colorScheme == .dark
            ? UsageTheme.red
            : Color(red: 211 / 255, green: 66 / 255, blue: 63 / 255)
    }
}

private struct ManagementGhostButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SettingsPalette.buttonText)
            .padding(.horizontal, 15)
            .frame(height: 31)
            .background(Color.white.opacity(isHovering ? 0.08 : 0.04), in: Capsule())
            .overlay {
                Capsule().stroke(Color.white.opacity(isHovering ? 0.14 : 0.08), lineWidth: 1)
            }
            .onHover { isHovering = $0 }
    }
}

private struct ManagementVisibilityButton: View {
    let isVisible: Bool
    let language: AppLanguage
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isVisible ? "checkmark.square.fill" : "square")
                Text(isVisible
                    ? language.text("Shown", "Visible")
                    : language.text("Show", "Mostrar"))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(isVisible ? SettingsPalette.accent : SettingsPalette.buttonText)
        .padding(.horizontal, 11)
        .frame(height: 31)
        .background(Color.white.opacity(isHovering ? 0.08 : 0.04), in: Capsule())
        .overlay {
            Capsule().stroke(
                isVisible ? SettingsPalette.accent.opacity(0.35) : Color.white.opacity(0.08),
                lineWidth: 1
            )
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel(language.text("Show assistant", "Mostrar asistente"))
        .accessibilityValue(isVisible ? language.text("On", "Sí") : language.text("Off", "No"))
    }
}

private struct ManagementPrimaryButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color(red: 7 / 255, green: 19 / 255, blue: 13 / 255))
            .padding(.horizontal, 19)
            .frame(height: 31)
            .background(SettingsPalette.accent, in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1) }
            .brightness(isHovering ? 0.08 : 0)
            .shadow(color: SettingsPalette.accent.opacity(0.5), radius: 8)
            .onHover { isHovering = $0 }
    }
}
