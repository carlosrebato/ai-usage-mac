import AIUsageMacServices
import AIUsageCore
import AppKit
import Foundation

@MainActor
enum ProviderDataAccessPicker {
    static func requestAccess(for provider: UsageProviderID) async throws -> Bool {
        let dataDirectory: ProviderDataDirectory = provider == .claude ? .claudeCode : .codex
        let providerName = provider == .claude ? "Claude" : "Codex"
        let folderName = provider == .claude ? ".claude" : ".codex"
        let language = AppLanguage.current
        let panel = NSOpenPanel()
        panel.title = language.text(
            "Add \(providerName) token history",
            "Añadir histórico de tokens de \(providerName)"
        )
        panel.message = language.text(
            provider == .claude
                ? "Select your .claude folder. AI Usage will only read numeric usage counters for local history and cost estimates."
                : "Select your .codex folder. AI Usage will only read numeric usage counters for local history and cost estimates.",
            provider == .claude
                ? "Selecciona tu carpeta .claude. AI Usage solo leerá contadores numéricos para histórico y estimaciones de coste."
                : "Selecciona tu carpeta .codex. AI Usage solo leerá contadores numéricos para histórico y estimaciones de coste."
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
        return true
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
