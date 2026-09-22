import AIUsageCore
import CryptoKit
import Foundation
import Security

public enum ProviderOAuthError: LocalizedError, Equatable, Sendable {
    case authenticationInProgress
    case invalidAuthorizationResponse
    case stateMismatch
    case missingAuthorizationCode
    case missingAccessToken
    case missingRefreshToken
    case rejected(status: Int)
    case keychain(OSStatus)
    case reauthenticationRequired

    public var errorDescription: String? {
        switch self {
        case .authenticationInProgress:
            "Another sign-in is already in progress. Finish or cancel it first."
        case .invalidAuthorizationResponse:
            "The provider returned an invalid authorization response."
        case .stateMismatch:
            "The sign-in response could not be verified."
        case .missingAuthorizationCode:
            "The provider did not return an authorization code."
        case .missingAccessToken:
            "The provider did not return an access token."
        case .missingRefreshToken:
            "The session cannot be refreshed. Sign in again."
        case .rejected(let status):
            "The provider rejected the authorization request (HTTP \(status))."
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .reauthenticationRequired:
            "The provider session has expired. Sign in again."
        }
    }
}

public enum ProviderOAuthSecurity {
    public static func verifyDeviceOnlyKeychainAccess() throws {
        let service = "com.carlosrebato.aiusage.oauth.keychain-probe"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
        defer { SecItemDelete(query as CFDictionary) }
        var add = query
        let value = Data("ai-usage-device-only-probe".utf8)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ProviderOAuthError.keychain(addStatus) }
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(read as CFDictionary, &result)
        guard readStatus == errSecSuccess, result as? Data == value else {
            throw ProviderOAuthError.keychain(readStatus)
        }
    }

    /// Removes only the legacy AI Usage-owned Claude item. It never queries or
    /// deletes Claude Code, Codex, ChatGPT or desktop-app Keychain services.
    public static func purgeLegacyAIUsageTokens() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.carlosrebato.aiusage.oauth.claude",
            kSecAttrAccount as String: "tokens",
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderOAuthError.keychain(status)
        }
    }
}

public struct ProviderAuthorizationRequest: Equatable, Sendable {
    public let provider: UsageProviderID
    public let authorizationURL: URL
    public let redirectURI: String
    public let state: String
    let verifier: String

    public init(
        provider: UsageProviderID,
        authorizationURL: URL,
        redirectURI: String,
        state: String,
        verifier: String
    ) {
        self.provider = provider
        self.authorizationURL = authorizationURL
        self.redirectURI = redirectURI
        self.state = state
        self.verifier = verifier
    }
}

public struct ProviderCredential: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?
    public let scopes: [String]

    public init(accessToken: String, accountID: String?, scopes: [String]) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.scopes = scopes
    }
}

struct StoredProviderToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date?
    let accountID: String?
    let scopes: [String]
}

protocol ProviderTokenVault: Sendable {
    func load() throws -> StoredProviderToken?
    func save(_ token: StoredProviderToken) throws
    func clear() throws
}

struct KeychainProviderTokenVault: ProviderTokenVault, Sendable {
    let provider: UsageProviderID
    private let account = "tokens-v1"

    func load() throws -> StoredProviderToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProviderOAuthError.keychain(status)
        }
        return try JSONDecoder().decode(StoredProviderToken.self, from: data)
    }

    func save(_ token: StoredProviderToken) throws {
        let data = try JSONEncoder().encode(token)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderOAuthError.keychain(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ProviderOAuthError.keychain(addStatus) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderOAuthError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.carlosrebato.aiusage.oauth.\(provider.rawValue)",
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

struct ProviderOAuthConfiguration: Equatable, Sendable {
    enum BodyEncoding: Sendable {
        case json
        case form
    }

    let provider: UsageProviderID
    let clientID: String
    let authorizeURL: URL
    let tokenURL: URL
    let scopes: [String]
    let bodyEncoding: BodyEncoding

    static let claude = ProviderOAuthConfiguration(
        provider: .claude,
        clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        authorizeURL: URL(string: "https://claude.ai/oauth/authorize")!,
        tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        scopes: ["user:profile"],
        bodyEncoding: .json
    )

    // Public client shipped by the open-source Codex CLI. Its effective scope
    // is intentionally documented here and never widened at runtime.
    static let codex = ProviderOAuthConfiguration(
        provider: .codex,
        clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
        authorizeURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
        scopes: [
            "openid", "profile", "email", "offline_access",
            "api.connectors.read", "api.connectors.invoke"
        ],
        bodyEncoding: .form
    )
}

public actor ProviderOAuthAccount {
    public nonisolated let provider: UsageProviderID
    public nonisolated let requestedScopes: [String]

    private let configuration: ProviderOAuthConfiguration
    private let vault: any ProviderTokenVault
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var refreshTask: Task<StoredProviderToken, Error>?

    public init(provider: UsageProviderID) {
        let configuration: ProviderOAuthConfiguration = provider == .claude ? .claude : .codex
        self.provider = provider
        requestedScopes = configuration.scopes
        self.configuration = configuration
        vault = KeychainProviderTokenVault(provider: provider)
        session = .shared
        now = Date.init
    }

    init(
        configuration: ProviderOAuthConfiguration,
        vault: any ProviderTokenVault,
        session: URLSession,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        provider = configuration.provider
        requestedScopes = configuration.scopes
        self.configuration = configuration
        self.vault = vault
        self.session = session
        self.now = now
    }

    public func authorizationRequest(redirectURI: String) throws -> ProviderAuthorizationRequest {
        let verifier = try Self.randomURLSafe(byteCount: 64)
        let state = try Self.randomURLSafe(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()

        var components = URLComponents(url: configuration.authorizeURL, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        switch provider {
        case .claude:
            items.append(URLQueryItem(name: "code", value: "true"))
        case .codex:
            items.append(contentsOf: [
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "originator", value: "codex_cli_rs")
            ])
        }
        components?.queryItems = items
        guard let url = components?.url else { throw ProviderOAuthError.invalidAuthorizationResponse }
        return ProviderAuthorizationRequest(
            provider: provider,
            authorizationURL: url,
            redirectURI: redirectURI,
            state: state,
            verifier: verifier
        )
    }

    public func completeAuthorization(
        callbackURL: URL,
        request: ProviderAuthorizationRequest
    ) async throws {
        guard request.provider == provider,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        else { throw ProviderOAuthError.invalidAuthorizationResponse }
        let values = Dictionary(
            components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        guard values["state"] == request.state else { throw ProviderOAuthError.stateMismatch }
        guard let code = values["code"], !code.isEmpty else {
            throw ProviderOAuthError.missingAuthorizationCode
        }

        let token = try await exchangeCode(
            code: code,
            verifier: request.verifier,
            redirectURI: request.redirectURI,
            state: request.state
        )
        try vault.save(token)
    }

    public func credential() async throws -> ProviderCredential? {
        guard var token = try vault.load() else { return nil }
        if tokenNeedsRefresh(token) {
            token = try await refreshSingleFlight(token)
        }
        return ProviderCredential(
            accessToken: token.accessToken,
            accountID: token.accountID,
            scopes: token.scopes
        )
    }

    public func signOut() throws {
        refreshTask?.cancel()
        refreshTask = nil
        try vault.clear()
    }

    public func isSignedIn() -> Bool {
        (try? vault.load()) != nil
    }

    private func refreshSingleFlight(_ current: StoredProviderToken) async throws -> StoredProviderToken {
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw ProviderOAuthError.missingRefreshToken
        }
        let task = Task { [configuration, session, now] in
            try await Self.refresh(
                current: current,
                refreshToken: refreshToken,
                configuration: configuration,
                session: session,
                now: now
            )
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let rotated = try await task.value
            // One atomic Keychain update replaces access + refresh tokens together.
            try vault.save(rotated)
            return rotated
        } catch let error as ProviderOAuthError where error == .rejected(status: 400)
            || error == .rejected(status: 401) {
            try? vault.clear()
            throw ProviderOAuthError.reauthenticationRequired
        }
    }

    private func exchangeCode(
        code: String,
        verifier: String,
        redirectURI: String,
        state: String
    ) async throws -> StoredProviderToken {
        var body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": configuration.clientID,
            "code_verifier": verifier
        ]
        if provider == .claude { body["state"] = state }
        return try await Self.requestToken(
            body: body,
            existing: nil,
            configuration: configuration,
            session: session,
            now: now
        )
    }

    private static func refresh(
        current: StoredProviderToken,
        refreshToken: String,
        configuration: ProviderOAuthConfiguration,
        session: URLSession,
        now: @escaping @Sendable () -> Date
    ) async throws -> StoredProviderToken {
        try await requestToken(
            body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": configuration.clientID
            ],
            existing: current,
            configuration: configuration,
            session: session,
            now: now
        )
    }

    private static func requestToken(
        body: [String: String],
        existing: StoredProviderToken?,
        configuration: ProviderOAuthConfiguration,
        session: URLSession,
        now: @escaping @Sendable () -> Date
    ) async throws -> StoredProviderToken {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch configuration.bodyEncoding {
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        case .form:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = body.sorted { $0.key < $1.key }.map(URLQueryItem.init)
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderOAuthError.invalidAuthorizationResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderOAuthError.rejected(status: http.statusCode)
        }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw ProviderOAuthError.missingAccessToken
        }
        let idToken = payload.idToken ?? existing?.idToken
        let accountID = Self.accountID(from: idToken) ?? existing?.accountID
        let expiresAt = payload.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
            ?? Self.expiration(from: accessToken)
            ?? existing?.expiresAt
        return StoredProviderToken(
            accessToken: accessToken,
            refreshToken: payload.refreshToken ?? existing?.refreshToken,
            idToken: idToken,
            expiresAt: expiresAt,
            accountID: accountID,
            scopes: configuration.scopes
        )
    }

    private func tokenNeedsRefresh(_ token: StoredProviderToken) -> Bool {
        guard let expiresAt = token.expiresAt else { return false }
        return expiresAt <= now().addingTimeInterval(60)
    }

    private static func randomURLSafe(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw ProviderOAuthError.invalidAuthorizationResponse
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func expiration(from jwt: String) -> Date? {
        guard let payload = jwtPayload(jwt), let seconds = payload["exp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func accountID(from idToken: String?) -> String? {
        guard let idToken, let payload = jwtPayload(idToken) else { return nil }
        if let value = payload["chatgpt_account_id"] as? String { return value }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any] {
            return auth["chatgpt_account_id"] as? String
        }
        return nil
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count > 1,
              let data = Data(base64URLEncoded: String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

public actor ProviderAccounts {
    public static let shared = ProviderAccounts()

    public nonisolated let claude: ProviderOAuthAccount
    public nonisolated let codex: ProviderOAuthAccount

    public init(
        claude: ProviderOAuthAccount = ProviderOAuthAccount(provider: .claude),
        codex: ProviderOAuthAccount = ProviderOAuthAccount(provider: .codex)
    ) {
        self.claude = claude
        self.codex = codex
    }

    public nonisolated func account(for provider: UsageProviderID) -> ProviderOAuthAccount {
        provider == .claude ? claude : codex
    }

    public func signOut(_ provider: UsageProviderID) async throws {
        try await account(for: provider).signOut()
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
