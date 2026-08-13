import AIUsageCore
import Foundation

protocol UsageConnector: Sendable {
    var providerID: UsageProviderID { get }
    func fetchSnapshot(allowInteraction: Bool) async throws -> ProviderUsageSnapshot
}

extension UsageConnector {
    func fetchSnapshot() async throws -> ProviderUsageSnapshot {
        try await fetchSnapshot(allowInteraction: false)
    }
}

enum UsageConnectorError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case notAuthenticated(String)
    case permissionRequired(String)
    case rateLimited(retryAfter: TimeInterval?)
    case malformedResponse
    case serverError(String)
    case missingUsageWindows

    var errorDescription: String? {
        let language = AppLanguage.current
        return switch self {
        case .executableNotFound:
            language.text(
                "The local Codex installation was not found",
                "No se encontró la instalación local de Codex"
            )
        case .launchFailed(let reason):
            "\(language.text("Codex could not be launched", "No se pudo iniciar Codex")): \(reason)"
        case .timedOut:
            language.text("The request took too long to respond", "La consulta tardó demasiado en responder")
        case .notAuthenticated(let message), .permissionRequired(let message):
            message
        case .rateLimited(let retryAfter):
            if let retryAfter {
                language.text(
                    "Updates are limited; retrying in \(Int(ceil(retryAfter / 60))) min",
                    "Actualizaciones limitadas; reintento en \(Int(ceil(retryAfter / 60))) min"
                )
            } else {
                language.text("Updates are temporarily limited", "Actualizaciones limitadas temporalmente")
            }
        case .malformedResponse:
            language.text("Codex returned an unknown response", "Codex devolvió una respuesta desconocida")
        case .serverError(let reason):
            reason
        case .missingUsageWindows:
            language.text("Codex did not return usage limits", "Codex no devolvió límites de uso")
        }
    }

    var retryAfter: TimeInterval? {
        guard case .rateLimited(let retryAfter) = self else { return nil }
        return retryAfter
    }
}
