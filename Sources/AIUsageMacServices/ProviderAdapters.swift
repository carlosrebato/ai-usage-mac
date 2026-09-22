import AIUsageCore
import AIUsageProviderServices
import Foundation

struct DirectUsageConnector: UsageConnector {
    let adapter: any DirectUsageAdapter
    var providerID: UsageProviderID { adapter.providerID }

    func fetchSnapshot(allowInteraction _: Bool) async throws -> ProviderUsageSnapshot {
        do {
            return try await adapter.fetchSnapshot()
        } catch let error as DirectUsageError {
            throw Self.map(error)
        } catch let error as ProviderOAuthError {
            switch error {
            case .reauthenticationRequired, .missingRefreshToken:
                throw UsageConnectorError.notAuthenticated(error.localizedDescription)
            default:
                throw UsageConnectorError.serverError(error.localizedDescription)
            }
        } catch let error as ProviderPolicyError {
            throw UsageConnectorError.serverError(error.localizedDescription)
        }
    }

    private static func map(_ error: DirectUsageError) -> UsageConnectorError {
        switch error {
        case .notAuthenticated, .accountIdentifierMissing:
            .notAuthenticated(error.localizedDescription)
        case .timedOut:
            .timedOut
        case .rateLimited(let retryAfter):
            .rateLimited(retryAfter: retryAfter)
        case .rejected(status: 401), .rejected(status: 403):
            .notAuthenticated(error.localizedDescription)
        case .rejected(let status):
            .serverError("Provider returned HTTP \(status)")
        case .malformedResponse:
            .malformedResponse
        case .missingUsageWindows:
            .missingUsageWindows
        case .transport:
            .serverError(error.localizedDescription)
        }
    }
}

/// Enforces direct → documented local fallback. Cache fallback remains in
/// UsageStore so a failed refresh can never remove the last useful card.
actor ResilientUsageConnector: UsageConnector {
    nonisolated let providerID: UsageProviderID
    private let direct: any UsageConnector
    private let localFallback: (any UsageConnector)?
    private let now: @Sendable () -> Date
    private var directFailures = 0
    private var circuitOpenUntil: Date?

    init(
        direct: any UsageConnector,
        localFallback: (any UsageConnector)?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(localFallback == nil || localFallback?.providerID == direct.providerID)
        providerID = direct.providerID
        self.direct = direct
        self.localFallback = localFallback
        self.now = now
    }

    func fetchSnapshot(allowInteraction: Bool) async throws -> ProviderUsageSnapshot {
        var directError: Error?
        if circuitOpenUntil.map({ $0 <= now() }) ?? true {
            do {
                let snapshot = try await direct.fetchSnapshot(allowInteraction: allowInteraction)
                directFailures = 0
                circuitOpenUntil = nil
                return snapshot
            } catch {
                directError = error
                if Self.shouldTripCircuit(error) {
                    directFailures += 1
                    if directFailures >= 3 {
                        let base = min(pow(2, Double(directFailures - 3)) * 60, 30 * 60)
                        let jitter = Double.random(in: 0...(base * 0.2))
                        circuitOpenUntil = now().addingTimeInterval(base + jitter)
                    }
                }
            }
        }

        if let localFallback {
            do {
                return try await localFallback.fetchSnapshot(allowInteraction: allowInteraction)
            } catch {
                if let directError { throw directError }
                throw error
            }
        }
        throw directError ?? UsageConnectorError.serverError("Provider temporarily unavailable")
    }

    private static func shouldTripCircuit(_ error: Error) -> Bool {
        guard let error = error as? UsageConnectorError else { return true }
        return switch error {
        case .missingUsageWindows, .notAuthenticated, .permissionRequired,
             .rateLimited, .executableNotFound:
            false
        case .launchFailed, .timedOut, .malformedResponse, .serverError:
            true
        }
    }
}

struct ClaudeStatusLineFallback: UsageConnector {
    let providerID = UsageProviderID.claude
    let reader: ClaudeStatuslineReader
    let now: @Sendable () -> Date

    init(
        reader: ClaudeStatuslineReader = ClaudeStatuslineReader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.now = now
    }

    func fetchSnapshot(allowInteraction _: Bool) async throws -> ProviderUsageSnapshot {
        guard let snapshot = reader.readFresh(now: now()) else {
            throw UsageConnectorError.missingUsageWindows
        }
        return snapshot
    }
}
