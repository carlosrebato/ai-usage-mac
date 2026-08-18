import AIUsageCore
import Foundation

actor CodexAppServerConnector: UsageConnector {
    nonisolated let providerID = UsageProviderID.codex

    private let credentialStore: any CodexCredentialLoading
    private let session: URLSession
    private let endpoint: URL
    private let now: @Sendable () -> Date

    init(
        credentialStore: any CodexCredentialLoading = CodexCredentialStore(),
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.session = session
        self.endpoint = endpoint
        self.now = now
    }

    func fetchSnapshot(allowInteraction _: Bool) async throws -> ProviderUsageSnapshot {
        let credential: CodexCredential
        do {
            credential = try credentialStore.load()
        } catch is ProviderDataAccessError {
            throw UsageConnectorError.permissionRequired(AppLanguage.current.text(
                "Connect Codex to authorize its .codex folder",
                "Conecta Codex para autorizar su carpeta .codex"
            ))
        } catch {
            throw UsageConnectorError.notAuthenticated(AppLanguage.current.text(
                "Sign in to Codex again",
                "Inicia sesión de nuevo en Codex"
            ))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw UsageConnectorError.timedOut
        } catch {
            throw UsageConnectorError.serverError(AppLanguage.current.text(
                "Could not connect to OpenAI",
                "No se pudo conectar con OpenAI"
            ))
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageConnectorError.malformedResponse
        }
        switch http.statusCode {
        case 200:
            return try CodexRateLimitsNormalizer.snapshot(from: data, observedAt: now())
        case 401, 403:
            throw UsageConnectorError.notAuthenticated(AppLanguage.current.text(
                "Open Codex to refresh its local session",
                "Abre Codex para renovar su sesión local"
            ))
        case 429:
            throw UsageConnectorError.rateLimited(retryAfter: Self.retryAfter(from: http, now: now()))
        default:
            throw UsageConnectorError.serverError(AppLanguage.current.text(
                "OpenAI returned status \(http.statusCode)",
                "OpenAI respondió con estado \(http.statusCode)"
            ))
        }
    }

    private static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw).map { max(0, $0.timeIntervalSince(now)) }
    }
}

struct CodexCredential: Equatable, Sendable {
    let accessToken: String
    let accountID: String
}

protocol CodexCredentialLoading: Sendable {
    func load() throws -> CodexCredential
}

struct CodexCredentialStore: CodexCredentialLoading, Sendable {
    private let dataAccess: ProviderDataAccess?
    private let directRoot: URL?

    init(dataAccess: ProviderDataAccess = .shared) {
        self.dataAccess = dataAccess
        directRoot = nil
    }

    init(codexRoot: URL) {
        dataAccess = nil
        directRoot = codexRoot
    }

    func load() throws -> CodexCredential {
        if let directRoot {
            return try Self.read(from: directRoot)
        }
        guard let dataAccess else {
            throw ProviderDataAccessError.accessNotGranted(provider: .codex)
        }
        return try dataAccess.withAccess(to: .codex) { root in
            try Self.read(from: root)
        }
    }

    static func parse(_ data: Data) throws -> CodexCredential {
        let file = try JSONDecoder().decode(AuthFile.self, from: data)
        guard
            let tokens = file.tokens,
            let accessToken = tokens.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !accessToken.isEmpty,
            let accountID = tokens.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !accountID.isEmpty
        else {
            throw UsageConnectorError.notAuthenticated("Codex auth.json has no ChatGPT session")
        }
        return CodexCredential(accessToken: accessToken, accountID: accountID)
    }

    private static func read(from root: URL) throws -> CodexCredential {
        let data = try Data(contentsOf: root.appendingPathComponent("auth.json"))
        return try parse(data)
    }
}

private struct AuthFile: Decodable {
    let tokens: AuthTokens?
}

private struct AuthTokens: Decodable {
    let accessToken: String?
    let accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
    }
}

enum CodexRateLimitsNormalizer {
    static func snapshot(from data: Data, observedAt: Date) throws -> ProviderUsageSnapshot {
        let response: CodexUsageResponse
        do {
            response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            throw UsageConnectorError.malformedResponse
        }

        guard let limits = response.rateLimit else {
            throw UsageConnectorError.missingUsageWindows
        }
        let windows = [limits.primaryWindow, limits.secondaryWindow].compactMap { $0 }
        let weekly = windows.first { ($0.limitWindowSeconds ?? 0) >= 7 * 24 * 60 * 60 }
        let session = weekly == nil
            ? limits.primaryWindow
            : windows.first { $0 != weekly }
        let fallbackWeekly = weekly
            ?? (limits.primaryWindow == session ? limits.secondaryWindow : limits.primaryWindow)

        guard session?.usedPercent != nil || fallbackWeekly?.usedPercent != nil else {
            throw UsageConnectorError.missingUsageWindows
        }

        let plan = response.planType?.capitalized
        return ProviderUsageSnapshot(
            id: .codex,
            session: usageWindow(session),
            weekly: usageWindow(fallbackWeekly),
            observedAt: observedAt,
            source: .live,
            message: plan.map { "Plan \($0)" } ?? AppLanguage.current.text(
                "Connected locally",
                "Conectado localmente"
            )
        )
    }

    private static func usageWindow(_ window: CodexRateLimitWindow?) -> UsageWindow {
        UsageWindow(
            usedPercent: window?.usedPercent.map { min(max($0, 0), 100) },
            resetsAt: window?.resetAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateLimitWindow?
    let secondaryWindow: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexRateLimitWindow: Decodable, Equatable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}
