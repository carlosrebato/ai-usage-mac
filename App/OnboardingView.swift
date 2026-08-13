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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppPreferenceKey.onboardingCompleted) private var onboardingCompleted = false
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @State private var busyProvider: UsageProviderID?
    @State private var accessError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                Text(headerTitle)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.35)
                    .foregroundStyle(primaryText)

                Text(headerSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 370)
            }
            .padding(.top, 26)

            VStack(spacing: 10) {
                providerCard(.claude)
                providerCard(.codex)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            HStack(spacing: 6) {
                Image(systemName: "lock")
                Text(language.text(
                    "Granted access is always read-only.",
                    "El acceso concedido es siempre de solo lectura."
                ))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tertiaryText)
            .padding(.top, 13)

            if let accessError {
                Text(accessError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(errorColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 8)
            }

            Spacer(minLength: 16)

            if isOnboarding {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle(
                        language.text("Open AI Usage at login", "Abrir AI Usage al iniciar sesión"),
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))

                    if launchAtLogin.status == .requiresApproval {
                        Button(language.text("Confirm in System Settings", "Confirmar en Ajustes del Sistema")) {
                            launchAtLogin.openSystemSettings()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
                    } else if let message = launchAtLogin.errorMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(errorColor)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 15)
            }

            Divider().opacity(colorScheme == .dark ? 0.25 : 0.55)

            HStack(spacing: 8) {
                if isOnboarding, !canStart {
                    Text(language.text(
                        "Connect at least one assistant to get started",
                        "Conecta al menos un asistente para empezar"
                    ))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tertiaryText)
                }

                Spacer()

                if isOnboarding {
                    Button(language.text("Not now", "Ahora no")) { finish(openDashboard: false) }
                        .controlSize(.small)

                    Button(language.text("Get started", "Empezar")) { finish(openDashboard: true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(actionColor)
                        .disabled(!canStart)
                } else {
                    Button(language.text("Done", "Listo")) {
                        dismissWindow(id: "onboarding")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(actionColor)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: isOnboarding ? 530 : 430)
        .background(panelBackground)
        .navigationTitle(windowTitle)
        .environment(\.locale, language.locale)
        .task {
            launchAtLogin.refresh()
            await store.refresh(force: true, allowInteraction: false)
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
                        "Checking the local Claude Desktop session.",
                        "Comprobando la sesión local de Claude Desktop."
                    )
                    : language.text(
                        "Looking for a local Codex session.",
                        "Buscando una sesión local de Codex."
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
                actionTitle: provider == .claude
                    ? language.text("Change access", "Cambiar acceso")
                    : language.text("Check", "Comprobar"),
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
            if provider == .claude {
                guard ClaudeDesktopDataAccess.shared.hasUsableAccess else {
                    return initialState(for: provider)
                }
                return CardState(
                    title: language.text("Confirm access to Claude", "Confirma el acceso a Claude"),
                    subtitle: message,
                    indicator: .attention,
                    actionTitle: language.text("Continue", "Continuar"),
                    actionIsQuiet: false
                )
            }
            return CardState(
                title: language.text("Codex needs permission", "Codex necesita permiso"),
                subtitle: message,
                indicator: .attention,
                actionTitle: language.text("Retry", "Reintentar"),
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
                    "Uses your local Claude Desktop session. macOS will ask you to choose its data folder.",
                    "Usa tu sesión local de Claude Desktop. macOS te pedirá elegir su carpeta de datos."
                )
                : language.text(
                    "Codex will be detected automatically on this Mac.",
                    "Detectaremos automáticamente Codex en este Mac."
                ),
            indicator: .none,
            actionTitle: language.text("Connect", "Conectar"),
            actionIsQuiet: false
        )
    }

    private func performAction(for provider: UsageProviderID) {
        accessError = nil
        let status = store.connectionStatuses.first { $0.id == provider }

        if provider == .claude, status?.phase == .connected {
            Task { await connectClaude() }
            return
        }
        if provider == .claude, status?.action == .grantPermission {
            if ClaudeDesktopDataAccess.shared.hasUsableAccess {
                Task { await refresh(provider) }
            } else {
                Task { await connectClaude() }
            }
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

    private func connectClaude() async {
        do {
            guard try await ClaudeDesktopAccessPicker.requestAccess() else { return }
            await refresh(.claude)
        } catch {
            accessError = error.localizedDescription
        }
    }

    private func refresh(_ provider: UsageProviderID) async {
        busyProvider = provider
        defer { busyProvider = nil }
        await store.refreshWhenIdle(force: true, allowInteraction: true)
    }

    private var canStart: Bool {
        store.connectionStatuses.contains { $0.isConnected }
    }

    private func finish(openDashboard: Bool) {
        onboardingCompleted = true
        if openDashboard { openWindow(id: "dashboard") }
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
