import AIUsageCore
import AIUsageDesignSystem
import AIUsageMacServices
import AppKit
import SwiftUI

struct ConnectionSetupView: View {
    let statuses: [ProviderConnectionStatus]
    let isRefreshing: Bool
    let errorMessage: String?
    let retry: () -> Void
    let grantClaudeDesktopAccess: () -> Void
    @AppStorage(AppPreferenceKey.language) private var language: AppLanguage = .english
    @State private var isSigningInToClaude = false
    @State private var signInError: String?

    private var pending: [ProviderConnectionStatus] {
        statuses.filter { status in
            switch status.phase {
            case .checking, .actionRequired: true
            case .connected, .retrying: false
            }
        }
    }

    var body: some View {
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("COMPLETE SETUP", "COMPLETA LA CONEXIÓN"))
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(UsageTheme.tertiaryText)
                    Text(language.text(
                        "AI Usage will use the sessions already available on this Mac.",
                        "AI Usage utilizará las sesiones que ya tienes en este Mac."
                    ))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UsageTheme.secondaryText)
                }

                ForEach(pending) { status in
                    connectionRow(status)
                }

                if let visibleError = signInError ?? errorMessage {
                    Text(visibleError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsageTheme.red)
                }
            }
            .padding(18)
            .usagePanel(cornerRadius: 16)
        }
    }

    private func connectionRow(_ status: ProviderConnectionStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: status.id.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UsageTheme.provider(status.id))
                .frame(width: 28, height: 28)
                .background(UsageTheme.provider(status.id).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(status.id.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UsageTheme.primaryText)
                Text(status.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UsageTheme.mutedText)
                    .lineLimit(2)
            }

            Spacer()

            if let action = status.action {
                Button(actionLabel(action, provider: status.id)) {
                    perform(action, provider: status.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
            } else if case .checking = status.phase {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func actionLabel(_ action: ProviderSetupAction, provider: UsageProviderID) -> String {
        switch action {
        case .grantPermission: language.text("Grant access", "Dar acceso")
        case .signIn:
            provider == .claude
                ? language.text("Sign in with Claude", "Iniciar sesión con Claude")
                : language.text("Open Codex", "Abrir Codex")
        case .install: language.text("Install", "Instalar")
        case .retry: language.text("Retry", "Reintentar")
        }
    }

    private func perform(_ action: ProviderSetupAction, provider: UsageProviderID) {
        switch action {
        case .grantPermission where provider == .claude:
            grantClaudeDesktopAccess()
        case .grantPermission, .retry:
            retry()
        case .signIn:
            if provider == .claude {
                guard !isSigningInToClaude else { return }
                isSigningInToClaude = true
                signInError = nil
                Task { @MainActor in
                    defer { isSigningInToClaude = false }
                    do {
                        try await ClaudeBrowserLogin.signIn()
                        retry()
                    } catch {
                        signInError = error.localizedDescription
                    }
                }
            } else {
                ProviderAppLauncher.open(provider, installationFallback: false)
            }
        case .install:
            ProviderAppLauncher.open(provider, installationFallback: true)
        }
    }
}

enum ProviderAppLauncher {
    static func open(_ provider: UsageProviderID, installationFallback: Bool) {
        if !installationFallback, openInstalledApplication(provider) { return }
        guard let url = downloadURL(provider) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func openInstalledApplication(_ provider: UsageProviderID) -> Bool {
        if provider == .claude,
           let deepLink = URL(string: "claude://claude.ai/new"),
           NSWorkspace.shared.open(deepLink) {
            return true
        }

        let names = provider == .claude ? ["Claude"] : ["Codex", "ChatGPT"]
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
        for root in roots {
            for name in names {
                let url = root.appendingPathComponent("\(name).app", isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    if NSWorkspace.shared.open(url) { return true }
                }
            }
        }
        return false
    }

    private static func downloadURL(_ provider: UsageProviderID) -> URL? {
        switch provider {
        case .claude: URL(string: "https://claude.com/download")
        case .codex: URL(string: "https://chatgpt.com/download/")
        }
    }
}
