import AIUsageMacServices
import AIUsageCore
import AppKit
import Foundation

@MainActor
enum ClaudeDesktopAccessPicker {
    static func requestAccess() async throws -> Bool {
        let language = AppLanguage.current
        let panel = NSOpenPanel()
        panel.title = language.text("Connect Claude", "Conectar Claude")
        panel.message = language.text(
            "Select the Claude folder. AI Usage will only read it to check your local session and counters.",
            "Selecciona la carpeta Claude. AI Usage sólo la utilizará en modo lectura para consultar tu sesión y contadores."
        )
        panel.prompt = language.text("Grant access", "Conceder acceso")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = ClaudeDesktopDataAccess.shared.resolvedURL()
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let folder = panel.url else { return false }
        try ClaudeDesktopDataAccess.shared.saveAccess(to: folder)
        return true
    }
}
