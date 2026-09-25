import AIUsageMacServices
import AIUsageCore
import AppKit
import Foundation

@MainActor
enum ProviderDataAccessPicker {
    static func requestAccess(
        for provider: UsageProviderID,
        duringInitialConnection: Bool = false
    ) async throws -> Bool {
        let dataDirectory: ProviderDataDirectory = provider == .claude ? .claudeCode : .codex
        let providerName = provider == .claude ? "Claude" : "Codex"
        let localToolName = provider == .claude ? "Claude Code" : "Codex CLI"
        let folderName = provider == .claude ? ".claude" : ".codex"
        let language = AppLanguage.current
        let panel = NSOpenPanel()
        panel.title = duringInitialConnection
            ? language.text("Optional local history", "Histórico local opcional")
            : language.text(
                "Add \(providerName) token history",
                "Añadir histórico de tokens de \(providerName)"
            )
        panel.message = duringInitialConnection
            ? language.text(
                "\(providerName) is connected. If you use \(localToolName) on this Mac, select \(folderName) for token history and cost estimates. Otherwise, choose Cancel; your usage limits will still work.",
                "\(providerName) está conectado. Si usas \(localToolName) en este Mac, selecciona \(folderName) para ver el histórico de tokens y las estimaciones de coste. Si no, pulsa Cancelar; los límites seguirán funcionando."
            )
            : language.text(
                "Select your \(folderName) folder. AI Usage will only read numeric usage counters for local history and cost estimates.",
                "Selecciona tu carpeta \(folderName). AI Usage solo leerá contadores numéricos para el histórico y las estimaciones de coste."
            )
        panel.prompt = language.text("Use \(folderName)", "Usar \(folderName)")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.showsHiddenFiles = true

        let home = FileManager.default.homeDirectoryForCurrentUser
        let suggested: URL
        if provider == .claude {
            suggested = home.appendingPathComponent(".claude", isDirectory: true)
        } else {
            suggested = home.appendingPathComponent(".codex", isDirectory: true)
        }
        let selectedFolder = ProviderDataAccess.shared.resolvedURL(for: dataDirectory)
            ?? suggested
        // Open at the parent and preselect the hidden provider folder so the
        // required macOS consent is clear without making people navigate to a
        // hidden directory by hand.
        panel.directoryURL = selectedFolder.deletingLastPathComponent()
        panel.nameFieldStringValue = selectedFolder.lastPathComponent

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let folder = panel.url else { return false }
        try ProviderDataAccess.shared.saveAccess(to: folder, for: dataDirectory)
        UserDefaults.standard.set(false, forKey: skippedHistoryKey(for: provider))
        return true
    }

    static func offerAccessDuringInitialConnection(for provider: UsageProviderID) async throws -> Bool {
        let directory: ProviderDataDirectory = provider == .claude ? .claudeCode : .codex
        guard !ProviderDataAccess.shared.hasUsableAccess(for: directory),
              !UserDefaults.standard.bool(forKey: skippedHistoryKey(for: provider)) else {
            return false
        }
        let granted = try await requestAccess(for: provider, duringInitialConnection: true)
        if !granted {
            UserDefaults.standard.set(true, forKey: skippedHistoryKey(for: provider))
        }
        return granted
    }

    private static func skippedHistoryKey(for provider: UsageProviderID) -> String {
        provider == .claude
            ? AppPreferenceKey.skippedClaudeTokenHistory
            : AppPreferenceKey.skippedCodexTokenHistory
    }
}

@MainActor
enum ClaudeDesktopAccessPicker {
    static func requestAccess() async throws -> Bool {
        try await ProviderDataAccessPicker.requestAccess(for: .claude)
    }
}

@MainActor
enum ClaudeCodeMetricsAccessPicker {
    static func requestAccess() async throws -> Bool {
        try await ProviderDataAccessPicker.requestAccess(for: .claude)
    }
}
