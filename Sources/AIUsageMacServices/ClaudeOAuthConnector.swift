import AIUsageCore
import CryptoKit
import Foundation
import LocalAuthentication
import Security

actor ClaudeOAuthConnector: UsageConnector {
    nonisolated let providerID = UsageProviderID.claude

    private let credentialStore: any ClaudeCredentialLoading
    private let desktopReader: any ClaudeDesktopCredentialReading
    private let statusline: ClaudeStatuslineReader
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var rateLimitedUntil: Date?
    private var desktopAutomaticAccessBlocked = false

    init(
        credentialStore: any ClaudeCredentialLoading = ClaudeCredentialStore(),
        desktopReader: any ClaudeDesktopCredentialReading = ClaudeDesktopCredentialReader(),
        statusline: ClaudeStatuslineReader = ClaudeStatuslineReader(),
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.desktopReader = desktopReader
        self.statusline = statusline
        self.session = session
        self.now = now
    }

    func fetchSnapshot(allowInteraction: Bool) async throws -> ProviderUsageSnapshot {
        if let rateLimitedUntil, now() < rateLimitedUntil {
            throw UsageConnectorError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSince(now()))
        }

        do {
            return try await fetchOAuthUsage(allowInteraction: allowInteraction)
        } catch {
            if let fallback = statusline.readFresh(now: now()) {
                return fallback
            }
            throw error
        }
    }

    private func fetchOAuthUsage(allowInteraction: Bool) async throws -> ProviderUsageSnapshot {
        let load = credentialStore.loadCandidates()
        if !load.credentials.isEmpty {
            do {
                return try await fetchUsage(using: load.credentials)
            } catch let error as UsageConnectorError {
                guard case .notAuthenticated = error else { throw error }
            }
        }

        if let credential = desktopReader.cachedCredential(now: now()) {
            return try await fetchUsage(using: [credential])
        }

        if !allowInteraction && desktopAutomaticAccessBlocked {
            throw UsageConnectorError.permissionRequired(
                AppLanguage.current.text(
                    "Connect Claude to authorize its data folder",
                    "Conecta Claude para autorizar su carpeta de datos"
                )
            )
        }

        switch desktopReader.load(allowInteraction: allowInteraction, now: now()) {
        case .available(let credential):
            desktopAutomaticAccessBlocked = false
            do {
                return try await fetchUsage(using: [credential])
            } catch let error as UsageConnectorError {
                if case .notAuthenticated = error {
                    throw UsageConnectorError.notAuthenticated(
                        AppLanguage.current.text(
                            "Open Claude Desktop to refresh its session",
                            "Abre Claude Desktop para renovar su sesión"
                        )
                    )
                }
                throw error
            }
        case .dataAccessRequired:
            if !allowInteraction {
                desktopAutomaticAccessBlocked = true
            }
            throw UsageConnectorError.permissionRequired(
                AppLanguage.current.text(
                    "Select the Claude Desktop data folder",
                    "Selecciona la carpeta de datos de Claude Desktop"
                )
            )
        case .keychainPermissionRequired:
            if !allowInteraction {
                desktopAutomaticAccessBlocked = true
            }
            throw UsageConnectorError.permissionRequired(
                AppLanguage.current.text(
                    "Confirm access to “Claude Safe Storage” in the Keychain prompt",
                    "Confirma el acceso a “Claude Safe Storage” en el aviso del Llavero"
                )
            )
        case .stale:
            throw UsageConnectorError.notAuthenticated(
                AppLanguage.current.text(
                    "Open Claude Desktop to refresh its session",
                    "Abre Claude Desktop para renovar su sesión"
                )
            )
        case .invalid:
            throw UsageConnectorError.serverError(
                AppLanguage.current.text(
                    "The Claude Desktop session could not be read",
                    "No se pudo leer la sesión de Claude Desktop"
                )
            )
        case .notFound:
            if !allowInteraction {
                desktopAutomaticAccessBlocked = true
                throw UsageConnectorError.permissionRequired(
                    AppLanguage.current.text(
                        "Connect Claude to authorize its data folder",
                        "Conecta Claude para autorizar su carpeta de datos"
                    )
                )
            }
            if load.permissionRequired {
                throw UsageConnectorError.permissionRequired(
                    AppLanguage.current.text(
                        "Allow access to the Claude Code login and refresh again",
                        "Permite acceso al login de Claude Code y vuelve a actualizar"
                    )
                )
            }
            throw UsageConnectorError.notAuthenticated(
                AppLanguage.current.text(
                    "Sign in to Claude Code or open Claude Desktop",
                    "Inicia sesión en Claude Code o abre Claude Desktop"
                )
            )
        }
    }

    private func fetchUsage(using credentials: [ClaudeCredential]) async throws -> ProviderUsageSnapshot {
        var lastAuthError: UsageConnectorError?
        for credential in credentials {
            if let scopes = credential.scopes, !scopes.isEmpty, !scopes.contains("user:profile") {
                lastAuthError = .notAuthenticated(
                    AppLanguage.current.text(
                        "Sign in to Claude Code again to enable usage limits",
                        "Vuelve a iniciar sesión en Claude Code para habilitar los límites"
                    )
                )
                continue
            }
            if let expiresAt = credential.expiresAt,
               expiresAt <= now().timeIntervalSince1970 * 1000 + 60_000
            {
                lastAuthError = .notAuthenticated(AppLanguage.current.text(
                    "The Claude Code session has expired",
                    "La sesión de Claude Code ha caducado"
                ))
                continue
            }

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.1.212", forHTTPHeaderField: "User-Agent")

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
                    "Could not connect to Anthropic",
                    "No se pudo conectar con Anthropic"
                ))
            }

            guard let http = response as? HTTPURLResponse else {
                throw UsageConnectorError.malformedResponse
            }
            switch http.statusCode {
            case 200:
                rateLimitedUntil = nil
                return try ClaudeUsageNormalizer.snapshot(
                    from: data,
                    plan: credential.displayPlan,
                    observedAt: now()
                )
            case 401, 403:
                lastAuthError = .notAuthenticated(AppLanguage.current.text(
                    "The Claude Code session needs to be refreshed",
                    "La sesión de Claude Code necesita renovarse"
                ))
                continue
            case 429:
                let retry = max(Self.retryAfter(from: http, now: now()) ?? 0, 5 * 60)
                rateLimitedUntil = now().addingTimeInterval(retry)
                throw UsageConnectorError.rateLimited(retryAfter: retry)
            default:
                throw UsageConnectorError.serverError(AppLanguage.current.text(
                    "Anthropic returned status \(http.statusCode)",
                    "Anthropic respondió con estado \(http.statusCode)"
                ))
            }
        }

        throw lastAuthError ?? UsageConnectorError.notAuthenticated(
            AppLanguage.current.text(
                "Sign in to Claude Code again",
                "Inicia sesión de nuevo en Claude Code"
            )
        )
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

struct ClaudeCredential: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Double?
    let subscriptionType: String?
    let rateLimitTier: String?
    let scopes: [String]?

    var displayPlan: String? {
        guard let subscriptionType = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subscriptionType.isEmpty
        else { return nil }
        let base = subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst().lowercased()
        guard let rateLimitTier,
              let match = rateLimitTier.range(of: #"\d+x"#, options: .regularExpression)
        else { return base }
        return "\(base) \(rateLimitTier[match])"
    }
}

struct ClaudeCredentialLoad: Sendable {
    let credentials: [ClaudeCredential]
    let permissionRequired: Bool
}

protocol ClaudeCredentialLoading: Sendable {
    func loadCandidates() -> ClaudeCredentialLoad
}

struct ClaudeCredentialStore: ClaudeCredentialLoading, Sendable {
    private static let baseService = "Claude Code-credentials"
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func loadCandidates() -> ClaudeCredentialLoad {
        var credentials: [ClaudeCredential] = []
        var permissionRequired = false

        for service in keychainServices() {
            let existence = keychainServiceExists(service: service)
            permissionRequired = permissionRequired || existence.permissionRequired
            guard existence.exists else { continue }

            for account in [NSUserName(), nil] as [String?] {
                let result = readKeychain(service: service, account: account)
                permissionRequired = permissionRequired || result.permissionRequired
                if let credential = result.credential,
                   !credentials.contains(where: { $0.accessToken == credential.accessToken })
                {
                    credentials.append(credential)
                }
            }
        }

        if let fileCredential = readFile(),
           !credentials.contains(where: { $0.accessToken == fileCredential.accessToken })
        {
            credentials.append(fileCredential)
        }

        return ClaudeCredentialLoad(credentials: credentials, permissionRequired: permissionRequired)
    }

    static func parseCredentialData(_ data: Data) -> ClaudeCredential? {
        guard
            let file = try? JSONDecoder().decode(CredentialsFile.self, from: data),
            let oauth = file.claudeAiOauth,
            let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !accessToken.isEmpty
        else { return nil }

        return ClaudeCredential(
            accessToken: accessToken,
            expiresAt: oauth.expiresAt,
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier,
            scopes: oauth.scopes
        )
    }

    private func readFile() -> ClaudeCredential? {
        let configDirectory = environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let url = configDirectory.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.parseCredentialData(data)
    }

    private func keychainServices() -> [String] {
        guard let literal = environment["CLAUDE_CONFIG_DIR"], !literal.isEmpty else {
            return [Self.baseService]
        }
        let normalized = literal.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return ["\(Self.baseService)-\(suffix)", Self.baseService]
    }

    private func readKeychain(
        service: String,
        account: String?
    ) -> (credential: ClaudeCredential?, permissionRequired: Bool) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let account, !account.isEmpty { query[kSecAttrAccount as String] = account }

        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return (nil, false) }
            return (Self.parseCredentialData(data), false)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return (nil, true)
        default:
            return (nil, false)
        }
    }

    private func keychainServiceExists(service: String) -> (exists: Bool, permissionRequired: Bool) {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            return (true, false)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return (false, true)
        default:
            return (false, false)
        }
    }
}

private struct CredentialsFile: Decodable {
    let claudeAiOauth: OAuthCredential?
}

private struct OAuthCredential: Decodable {
    let accessToken: String?
    let expiresAt: Double?
    let subscriptionType: String?
    let rateLimitTier: String?
    let scopes: [String]?
}

enum ClaudeUsageNormalizer {
    static func snapshot(from data: Data, plan: String?, observedAt: Date) throws -> ProviderUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageConnectorError.malformedResponse
        }

        let session = window(root["five_hour"])
        let weekly = window(root["seven_day"])
        guard session.usedPercent != nil || weekly.usedPercent != nil else {
            throw UsageConnectorError.missingUsageWindows
        }

        return ProviderUsageSnapshot(
            id: .claude,
            session: session,
            weekly: weekly,
            observedAt: observedAt,
            source: .live,
            message: plan.map { "Plan \($0)" } ?? AppLanguage.current.text(
                "Connected locally",
                "Conectado localmente"
            )
        )
    }

    private static func window(_ value: Any?) -> UsageWindow {
        guard let object = value as? [String: Any] else {
            return UsageWindow(usedPercent: nil, resetsAt: nil)
        }
        let rawPercent = (object["utilization"] as? NSNumber)?.doubleValue
        let percent = rawPercent.map { min(max($0, 0), 100) }
        return UsageWindow(usedPercent: percent, resetsAt: resetDate(object["resets_at"]))
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let number = (value as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: abs(number) < 1e10 ? number : number / 1000)
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

struct ClaudeStatuslineReader: Sendable {
    let fileURL: URL
    let maximumAge: TimeInterval

    init(fileURL: URL? = nil, maximumAge: TimeInterval = 10 * 60) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/nspanel-rate-limits.json")
        self.maximumAge = maximumAge
    }

    func readFresh(now: Date) -> ProviderUsageSnapshot? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let modifiedAt = attributes[.modificationDate] as? Date,
            now.timeIntervalSince(modifiedAt) <= maximumAge,
            let data = try? Data(contentsOf: fileURL),
            let payload = try? JSONDecoder().decode(StatuslinePayload.self, from: data),
            payload.sessionPercent != nil || payload.weekPercent != nil
        else { return nil }

        return ProviderUsageSnapshot(
            id: .claude,
            session: UsageWindow(usedPercent: payload.sessionPercent, resetsAt: parse(payload.resetAt)),
            weekly: UsageWindow(usedPercent: payload.weekPercent, resetsAt: parse(payload.weekResetAt)),
            observedAt: parse(payload.lastUpdated) ?? modifiedAt,
            source: .cached,
            message: "Claude Code statusline"
        )
    }

    private func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct StatuslinePayload: Decodable {
    let sessionPercent: Double?
    let weekPercent: Double?
    let resetAt: String?
    let weekResetAt: String?
    let lastUpdated: String?
}
