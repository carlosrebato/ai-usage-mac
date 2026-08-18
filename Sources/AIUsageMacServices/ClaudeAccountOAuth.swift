import AIUsageCore
import Foundation
import Security

public enum ClaudeAccountOAuthError: LocalizedError, Sendable {
    case invalidResponse
    case rejected(status: Int)
    case missingAccessToken
    case missingRefreshToken
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return AppLanguage.current.text(
                "Claude returned an invalid sign-in response.",
                "Claude devolvió una respuesta de acceso no válida."
            )
        case .rejected(let status):
            return AppLanguage.current.text(
                "Claude could not complete sign-in (HTTP \(status)).",
                "Claude no pudo completar el acceso (HTTP \(status))."
            )
        case .missingAccessToken:
            return AppLanguage.current.text(
                "Claude did not return an access token.",
                "Claude no devolvió un token de acceso."
            )
        case .missingRefreshToken:
            return AppLanguage.current.text(
                "The Claude session has expired. Sign in again.",
                "La sesión de Claude ha caducado. Inicia sesión de nuevo."
            )
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            return AppLanguage.current.text(
                "AI Usage could not save the Claude login in Keychain: \(detail)",
                "AI Usage no pudo guardar el acceso de Claude en el Llavero: \(detail)"
            )
        }
    }
}

public enum ClaudeAccountOAuth {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizeURL = "https://claude.ai/oauth/authorize"
    public static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    public static let scopes = "org:create_api_key user:profile user:inference"

    public static func completeSignIn(
        code: String,
        verifier: String,
        redirectURI: String,
        state: String
    ) async throws {
        let token = try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": state
        ])
        try TokenStore.save(token)
    }

    public static func signOut() {
        TokenStore.clear()
    }

    /// Exercises the same Data Protection Keychain path used by OAuth without
    /// touching a real Claude token. Intended for signed-artifact smoke tests.
    public static func verifyKeychainAccess() throws {
        try TokenStore.verifyAccess()
    }

    static func credential(now: Date) async throws -> ClaudeCredential? {
        try await TokenManager.shared.credential(now: now)
    }

    private static func refresh(_ refreshToken: String) async throws -> StoredToken {
        try await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ], existingRefreshToken: refreshToken)
    }

    private static func requestToken(
        _ body: [String: String],
        existingRefreshToken: String? = nil
    ) async throws -> StoredToken {
        guard let url = URL(string: tokenURL) else { throw ClaudeAccountOAuthError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAccountOAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeAccountOAuthError.rejected(status: http.statusCode)
        }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw ClaudeAccountOAuthError.missingAccessToken
        }
        return StoredToken(
            accessToken: accessToken,
            refreshToken: payload.refreshToken ?? existingRefreshToken,
            expiresAt: payload.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
    }

    private actor TokenManager {
        static let shared = TokenManager()
        private var refreshTask: Task<StoredToken, Error>?

        func credential(now: Date) async throws -> ClaudeCredential? {
            guard var token = TokenStore.load() else { return nil }
            if let expiresAt = token.expiresAt, expiresAt <= now.addingTimeInterval(60) {
                guard let refreshToken = token.refreshToken else {
                    throw ClaudeAccountOAuthError.missingRefreshToken
                }
                if let refreshTask {
                    token = try await refreshTask.value
                } else {
                    let task = Task { try await ClaudeAccountOAuth.refresh(refreshToken) }
                    refreshTask = task
                    defer { refreshTask = nil }
                    token = try await task.value
                    try TokenStore.save(token)
                }
            }
            return ClaudeCredential(
                accessToken: token.accessToken,
                expiresAt: token.expiresAt.map { $0.timeIntervalSince1970 * 1_000 },
                subscriptionType: nil,
                rateLimitTier: nil,
                scopes: ["user:profile", "user:inference"]
            )
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct StoredToken: Codable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    private enum TokenStore {
        private static let service = "com.carlosrebato.aiusage.oauth.claude"
        private static let account = "tokens"
        private static let probeService = "com.carlosrebato.aiusage.oauth.keychain-probe"

        static func load() -> StoredToken? {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data
            else { return nil }
            return try? JSONDecoder().decode(StoredToken.self, from: data)
        }

        static func save(_ token: StoredToken) throws {
            let data = try JSONEncoder().encode(token)
            let update = [kSecValueData as String: data]
            let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw ClaudeAccountOAuthError.keychain(status) }
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ClaudeAccountOAuthError.keychain(addStatus) }
        }

        static func clear() {
            SecItemDelete(baseQuery as CFDictionary)
        }

        static func verifyAccess() throws {
            let probe = Data("ai-usage-keychain-probe".utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true
            ]
            SecItemDelete(query as CFDictionary)
            defer { SecItemDelete(query as CFDictionary) }

            var add = query
            add[kSecValueData as String] = probe
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ClaudeAccountOAuthError.keychain(addStatus)
            }

            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let readStatus = SecItemCopyMatching(read as CFDictionary, &result)
            guard readStatus == errSecSuccess, result as? Data == probe else {
                throw ClaudeAccountOAuthError.keychain(readStatus)
            }
        }

        private static var baseQuery: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true
            ]
        }
    }
}
