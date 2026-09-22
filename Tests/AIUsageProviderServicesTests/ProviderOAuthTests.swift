import Foundation
import Testing
import AIUsageCore
@testable import AIUsageProviderServices

private final class MemoryVaultStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredProviderToken?

    init(_ value: StoredProviderToken? = nil) { self.value = value }
    func load() -> StoredProviderToken? { lock.withLock { value } }
    func save(_ value: StoredProviderToken) { lock.withLock { self.value = value } }
    func clear() { lock.withLock { value = nil } }
}

private struct MemoryVault: ProviderTokenVault {
    let storage: MemoryVaultStorage
    func load() throws -> StoredProviderToken? { storage.load() }
    func save(_ token: StoredProviderToken) throws { storage.save(token) }
    func clear() throws { storage.clear() }
}

private final class OAuthURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() { }
}

@Suite(.serialized)
struct ProviderOAuthTests {
    @Test func claudeUsesTheBlockingLeastPrivilegeScope() {
        #expect(ProviderOAuthConfiguration.claude.scopes == ["user:profile"])
        #expect(!ProviderOAuthConfiguration.claude.scopes.contains("user:" + "inference"))
        #expect(!ProviderOAuthConfiguration.claude.scopes.contains("org:" + "create_api_key"))
    }

    @Test func codexCapabilitiesAreFixedAndDocumented() {
        #expect(ProviderOAuthConfiguration.codex.scopes == [
            "openid", "profile", "email", "offline_access",
            "api.connectors.read", "api.connectors.invoke"
        ])
    }

    @Test func authorizationUsesPKCEAndRandomState() async throws {
        let account = ProviderOAuthAccount(
            configuration: .claude,
            vault: MemoryVault(storage: MemoryVaultStorage()),
            session: testSession()
        )
        let first = try await account.authorizationRequest(
            redirectURI: "http://localhost:54134/callback"
        )
        let second = try await account.authorizationRequest(
            redirectURI: "http://localhost:54134/callback"
        )
        let query = URLComponents(url: first.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(first.state != second.state)
        #expect(query?.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(query?.first { $0.name == "scope" }?.value == "user:profile")
        #expect(query?.first { $0.name == "code" }?.value == "true")
        #expect(query?.first { $0.name == "redirect_uri" }?.value == "http://localhost:54134/callback")
    }

    @Test func manipulatedCallbackIsRejectedBeforeTokenExchange() async throws {
        let account = ProviderOAuthAccount(
            configuration: .claude,
            vault: MemoryVault(storage: MemoryVaultStorage()),
            session: testSession()
        )
        let request = try await account.authorizationRequest(
            redirectURI: "https://platform.claude.com/oauth/code/callback"
        )
        let callback = URL(string: "https://platform.claude.com/oauth/code/callback?code=secret&state=wrong")!
        await #expect(throws: ProviderOAuthError.stateMismatch) {
            try await account.completeAuthorization(callbackURL: callback, request: request)
        }
    }

    @Test func tenConcurrentCredentialsPerformOneRefreshAndRotateAtomically() async throws {
        let expired = StoredProviderToken(
            accessToken: "expired",
            refreshToken: "refresh-old",
            idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1),
            accountID: nil,
            scopes: ["user:profile"]
        )
        let storage = MemoryVaultStorage(expired)
        let count = LockedCounter()
        OAuthURLProtocol.handler = { request in
            count.increment()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"access_token":"fresh","refresh_token":"refresh-new","expires_in":3600}"#.utf8))
        }
        let account = ProviderOAuthAccount(
            configuration: .claude,
            vault: MemoryVault(storage: storage),
            session: testSession(),
            now: { Date(timeIntervalSince1970: 100) }
        )

        try await withThrowingTaskGroup(of: ProviderCredential?.self) { group in
            for _ in 0..<10 { group.addTask { try await account.credential() } }
            for try await credential in group { #expect(credential?.accessToken == "fresh") }
        }
        #expect(count.value == 1)
        #expect(storage.load()?.refreshToken == "refresh-new")
    }

    @Test func directNormalizersTolerateAdditionalWindows() throws {
        let claude = try ClaudeDirectUsageNormalizer.snapshot(
            from: Data(#"{"five_hour":{"utilization":25},"seven_day":{"utilization":40},"seven_day_opus":{"utilization":10}}"#.utf8),
            plan: "Max 20x",
            observedAt: .now
        )
        let codex = try CodexDirectUsageNormalizer.snapshot(
            from: Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":22,"limit_window_seconds":18000},"secondary_window":{"used_percent":51,"limit_window_seconds":604800}},"credits":{}}"#.utf8),
            observedAt: .now
        )
        #expect(claude.weekly.usedPercent == 40)
        #expect(claude.message == "Plan Max 20x")
        #expect(codex.session.usedPercent == 22)
        #expect(codex.weekly.usedPercent == 51)
        #expect(codex.message == "Plan Plus")
    }

    @Test func claudeParsesFractionalAndNumericResetTimes() throws {
        let snapshot = try ClaudeDirectUsageNormalizer.snapshot(
            from: Data(#"{"five_hour":{"utilization":25,"resets_at":"2026-09-22T13:45:12.123456Z"},"seven_day":{"utilization":40,"resets_at":1790082000000}}"#.utf8),
            observedAt: .now
        )

        #expect(snapshot.session.resetsAt != nil)
        #expect(snapshot.weekly.resetsAt == Date(timeIntervalSince1970: 1_790_082_000))
    }

    @Test func claudeProfileRestoresConcretePlanNames() {
        let max = ClaudeProfileNormalizer.plan(
            from: Data(#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#.utf8)
        )
        let pro = ClaudeProfileNormalizer.plan(
            from: Data(#"{"account":{"has_claude_pro":true}}"#.utf8)
        )
        let team = ClaudeProfileNormalizer.plan(
            from: Data(#"{"organization":{"organization_type":"claude_team"}}"#.utf8)
        )

        #expect(max == "Max 20x")
        #expect(pro == "Pro")
        #expect(team == "Team")
    }

    @Test func claudeAdapterCombinesUsageTimersAndProfilePlan() async throws {
        let token = StoredProviderToken(
            accessToken: "claude-token",
            refreshToken: "refresh",
            idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 10_000),
            accountID: nil,
            scopes: ["user:profile"]
        )
        let account = ProviderOAuthAccount(
            configuration: .claude,
            vault: MemoryVault(storage: MemoryVaultStorage(token)),
            session: testSession(),
            now: { Date(timeIntervalSince1970: 100) }
        )
        OAuthURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.url?.path == "/profile" {
                return (
                    response,
                    Data(#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}}"#.utf8)
                )
            }
            return (
                response,
                Data(#"{"five_hour":{"utilization":4,"resets_at":"2026-09-22T13:45:12.123456Z"},"seven_day":{"utilization":3,"resets_at":"2026-09-29T00:00:00Z"}}"#.utf8)
            )
        }
        let adapter = ClaudeDirectAdapter(
            account: account,
            session: testSession(),
            endpoint: URL(string: "https://example.com/usage")!,
            profileEndpoint: URL(string: "https://example.com/profile")!,
            now: { Date(timeIntervalSince1970: 100) }
        )

        let snapshot = try await adapter.fetchSnapshot()

        #expect(snapshot.message == "Plan Max 5x")
        #expect(snapshot.session.resetsAt != nil)
        #expect(snapshot.weekly.resetsAt != nil)
    }

    @Test func aThrottledAdapterCanProbeAgainAfterTheStoreDecidesToRetry() async throws {
        let token = StoredProviderToken(
            accessToken: "claude-token",
            refreshToken: "refresh",
            idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 10_000),
            accountID: nil,
            scopes: ["user:profile"]
        )
        let account = ProviderOAuthAccount(
            configuration: .claude,
            vault: MemoryVault(storage: MemoryVaultStorage(token)),
            session: testSession(),
            now: { Date(timeIntervalSince1970: 100) }
        )
        let requests = LockedCounter()
        OAuthURLProtocol.handler = { request in
            if request.url?.path == "/usage" {
                requests.increment()
                if requests.value == 1 {
                    return (
                        HTTPURLResponse(
                            url: request.url!, statusCode: 429, httpVersion: nil,
                            headerFields: ["Retry-After": "3600"]
                        )!,
                        Data()
                    )
                }
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!,
                request.url?.path == "/profile"
                    ? Data(#"{"organization":{"organization_type":"claude_pro"}}"#.utf8)
                    : Data(#"{"five_hour":{"utilization":4,"resets_at":"2026-09-22T13:45:12Z"},"seven_day":{"utilization":3,"resets_at":"2026-09-29T00:00:00Z"}}"#.utf8)
            )
        }
        let adapter = ClaudeDirectAdapter(
            account: account,
            session: testSession(),
            endpoint: URL(string: "https://example.com/usage")!,
            profileEndpoint: URL(string: "https://example.com/profile")!,
            now: { Date(timeIntervalSince1970: 100) }
        )

        do {
            _ = try await adapter.fetchSnapshot()
            Issue.record("First request should be throttled")
        } catch DirectUsageError.rateLimited(let retryAfter) {
            #expect(retryAfter == 3_600)
        }
        let recovered = try await adapter.fetchSnapshot()
        #expect(recovered.source == .live)
        #expect(requests.value == 2)
    }

    private func testSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
