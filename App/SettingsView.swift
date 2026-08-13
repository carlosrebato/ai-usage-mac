import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import AppKit
import SwiftUI
import WidgetKit

struct SettingsView: View {
    private struct ProviderPresentation {
        let detail: String
        let badge: String
        let color: Color
    }

    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var assistantSetupContext: AssistantSetupContext
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppPreferenceKey.automaticRefresh) private var automaticRefresh = true
    @AppStorage(AppPreferenceKey.showPercentageInMenuBar) private var showPercentage = true
    @AppStorage(AppPreferenceKey.showResetTimesInMenuBar) private var showResetTimes = false
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            section(language.text("General", "General")) {
                preferenceRow(
                    systemName: "arrow.triangle.2.circlepath",
                    title: language.text("Automatic refresh", "Actualizar automáticamente"),
                    subtitle: language.text(
                        "Keeps your limits current in the background",
                        "Mantiene los límites al día en segundo plano"
                    ),
                    isOn: $automaticRefresh
                )

                Divider().padding(.leading, 42)

                preferenceRow(
                    systemName: "menubar.rectangle",
                    title: language.text("Percentage in the menu bar", "Porcentaje en la barra de menú"),
                    subtitle: language.text(
                        "Shows usage without opening the app",
                        "Muestra el uso sin abrir la aplicación"
                    ),
                    isOn: $showPercentage
                )

                Divider().padding(.leading, 42)

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

                Divider().padding(.leading, 42)
                languageRow
            }

            assistantsSection
            launchSection
            privacyCallout

            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 520, height: 668)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(language.text("AI Usage Settings", "Ajustes de AI Usage"))
        .environment(\.locale, language.locale)
        .onAppear {
            launchAtLogin.refresh()
            language.persistForExtensions()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("AIUsageBrand")
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage")
                    .font(.system(size: 18, weight: .bold))
                Text(language.text("Preferences and local connections", "Preferencias y conexiones locales"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var assistantsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(language.text("Assistants", "Asistentes"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(language.text("Manage…", "Gestionar…")) {
                    assistantSetupContext.mode = .management
                    openWindow(id: "onboarding")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 3)

            VStack(spacing: 0) {
                providerRow(.claude)
                Divider().padding(.leading, 52)
                providerRow(.codex)
            }
            .settingsCard()
        }
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(language.text("Startup", "Inicio"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    settingsIcon("power", color: .indigo)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("Open at login", "Abrir al iniciar sesión"))
                            .font(.system(size: 13, weight: .medium))
                        Text(launchAtLoginDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(launchAtLogin.errorMessage == nil ? .secondary : UsageTheme.red)
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
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if launchAtLogin.status == .requiresApproval {
                    Button(language.text("Confirm in System Settings", "Confirmar en Ajustes del Sistema")) {
                        launchAtLogin.openSystemSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 42)
                }
            }
            .padding(12)
            .settingsCard()
        }
    }

    private var privacyCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            Text(language.text(
                "Counters are processed locally with read-only access. AI Usage does not store or send the content of your conversations.",
                "Los contadores se procesan localmente y con acceso de solo lectura. AI Usage no almacena ni envía el contenido de tus conversaciones."
            ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(language.text(
                "Estimated API equivalent · current reset period · USD",
                "Equivalente API estimado · periodo de reinicio actual · USD"
            ))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Text("v\(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            Button(language.text("Quit AI Usage", "Salir de AI Usage"), role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)

            VStack(spacing: 0) { content() }
                .settingsCard()
        }
    }

    private func preferenceRow(
        systemName: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            settingsIcon(systemName, color: .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var languageRow: some View {
        HStack(spacing: 12) {
            settingsIcon("globe", color: .teal)

            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("Language", "Idioma"))
                    .font(.system(size: 13, weight: .medium))
                Text(language.text("Changes the entire app", "Cambia toda la aplicación"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 112)
            .onChange(of: language) { _, newLanguage in
                newLanguage.persistForExtensions()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private func providerRow(_ provider: UsageProviderID) -> some View {
        let presentation = providerPresentation(provider)

        return HStack(spacing: 12) {
            ProviderGlyph(provider: provider, size: 16, color: .primary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(provider == .claude ? "Claude" : "Codex")
                    .font(.system(size: 13, weight: .semibold))
                Text(presentation.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle().fill(presentation.color).frame(width: 7, height: 7)
                Text(presentation.badge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    private func providerPresentation(_ provider: UsageProviderID) -> ProviderPresentation {
        let status = store.connectionStatuses.first { $0.id == provider }
        let snapshot = store.snapshots.first { $0.id == provider }

        switch status?.phase {
        case .connected:
            return ProviderPresentation(
                detail: snapshot?.message ?? status?.message ?? language.text("Local session detected", "Sesión local detectada"),
                badge: language.text("Connected", "Conectado"),
                color: UsageTheme.green
            )
        case .checking:
            return ProviderPresentation(
                detail: language.text("Checking the local session…", "Comprobando la sesión local…"),
                badge: language.text("Checking", "Comprobando"),
                color: UsageTheme.amber
            )
        case .actionRequired:
            return ProviderPresentation(
                detail: status?.message ?? language.text("Setup required", "Necesita configuración"),
                badge: language.text("Attention", "Atención"),
                color: UsageTheme.amber
            )
        case .retrying:
            return ProviderPresentation(
                detail: status?.message ?? language.text("Could not connect", "No se pudo conectar"),
                badge: language.text("Error", "Error"),
                color: UsageTheme.red
            )
        case .none:
            return ProviderPresentation(
                detail: snapshot?.message ?? language.text("No data", "Sin datos"),
                badge: language.text("Not connected", "Sin conectar"),
                color: .secondary
            )
        }
    }

    private func settingsIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
    }

    private var launchAtLoginDetail: String {
        if let error = launchAtLogin.errorMessage {
            return "\(language.text("Could not change this setting", "No se pudo cambiar")): \(error)"
        }
        return switch launchAtLogin.status {
        case .enabled: language.text("AI Usage will open automatically", "AI Usage se abrirá automáticamente")
        case .requiresApproval: language.text("Confirm it in System Settings", "Falta confirmarlo en Ajustes del Sistema")
        case .disabled: language.text("You can change this at any time", "Puedes cambiarlo en cualquier momento")
        case .unavailable: language.text("Enable it to register with macOS", "Actívalo para registrarlo en macOS")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

private extension View {
    func settingsCard() -> some View {
        background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}
