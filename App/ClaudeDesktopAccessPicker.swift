import AIUsageMacServices
import AIUsageCore
import AppKit
import Foundation

@MainActor
enum ProviderDataAccessPicker {
    static func requestAccess(for provider: UsageProviderID) async throws -> Bool {
        let dataDirectory: ProviderDataDirectory = provider == .claude ? .claude : .codex
        let providerName = provider == .claude ? "Claude" : "Codex"
        let language = AppLanguage.current
        let panel = NSOpenPanel()
        panel.title = language.text("Connect \(providerName)", "Conectar \(providerName)")
        panel.message = language.text(
            provider == .claude
                ? "Select your .claude folder. AI Usage will only read your Claude Code credentials and usage counters."
                : "Select your .codex folder. AI Usage will only read local credentials and usage counters.",
            provider == .claude
                ? "Selecciona tu carpeta .claude. AI Usage solo leerá las credenciales y contadores de Claude Code."
                : "Selecciona tu carpeta .codex. AI Usage solo leerá credenciales locales y contadores de uso."
        )
        panel.prompt = language.text("Grant read-only access", "Conceder acceso de solo lectura")
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
        panel.directoryURL = ProviderDataAccess.shared.resolvedURL(for: dataDirectory)
            ?? suggested

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let folder = panel.url else { return false }
        try ProviderDataAccess.shared.saveAccess(to: folder, for: dataDirectory)
        // The Claude Code folder contains both the OAuth credential and token
        // history. Reuse the same least-privilege grant instead of asking for
        // the identical folder a second time in Settings.
        if provider == .claude, folder.standardizedFileURL.lastPathComponent == ".claude" {
            try ProviderDataAccess.shared.saveAccess(to: folder, for: .claudeCode)
        }
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
        let language = AppLanguage.current
        let panel = NSOpenPanel()
        panel.title = language.text("Add Claude token history", "Añadir histórico de tokens de Claude")
        panel.message = language.text(
            "AI Usage found your Claude data folder. Confirm read-only access to calculate token totals and estimated API-equivalent cost.",
            "AI Usage ha encontrado tu carpeta de datos de Claude. Confirma el acceso de solo lectura para calcular tokens y el coste equivalente estimado de API."
        )
        panel.prompt = language.text("Use .claude", "Usar .claude")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.showsHiddenFiles = true
        let suggestedFolder = ProviderDataAccess.shared.resolvedURL(for: .claudeCode)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        // Open at the parent and preselect the hidden folder. This keeps the
        // mandatory macOS consent step while avoiding Finder shortcuts or
        // asking the user to navigate hidden files manually.
        panel.directoryURL = suggestedFolder.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedFolder.lastPathComponent

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let folder = panel.url else { return false }
        try ProviderDataAccess.shared.saveAccess(to: folder, for: .claudeCode)
        return true
    }
}
