import CryptoKit
import Foundation
import Testing
import AIUsageCore
@testable import AIUsageProviderServices

private final class PolicyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: Data] = [:]

    static func register(_ data: Data, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = data
    }

    private static func response(for url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return responses[url]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let data = Self.response(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ProviderKillSwitchTests {
    @Test func acceptsOnlyAValidSignedPolicy() throws {
        let privateKey = P256.Signing.PrivateKey()
        let policy = ProviderKillSwitch.Policy(
            schemaVersion: 1,
            disabledProviders: [.claude],
            minimumVersion: "1.2.0",
            notice: "Safety pause",
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        let payload = try JSONEncoder().encode(policy)
        let signature = try privateKey.signature(for: payload).derRepresentation
        let envelope = try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(),
            "signature": signature.base64EncodedString()
        ])

        let verified = try ProviderKillSwitch.verify(
            envelope,
            publicKey: privateKey.publicKey
        )
        #expect(verified == policy)
    }

    @Test func rejectsTamperedPolicy() throws {
        let privateKey = P256.Signing.PrivateKey()
        let original = Data(#"{"schemaVersion":1,"disabledProviders":[]}"#.utf8)
        let signature = try privateKey.signature(for: original).derRepresentation
        let tampered = Data(#"{"schemaVersion":1,"disabledProviders":["codex"]}"#.utf8)
        let envelope = try JSONSerialization.data(withJSONObject: [
            "payload": tampered.base64EncodedString(),
            "signature": signature.base64EncodedString()
        ])

        #expect(throws: Error.self) {
            try ProviderKillSwitch.verify(envelope, publicKey: privateKey.publicKey)
        }
    }

    @Test func versionComparisonIsNumeric() {
        #expect(ProviderKillSwitch.compareVersions("1.9", "1.10") == .orderedAscending)
        #expect(ProviderKillSwitch.compareVersions("2.0", "1.10") == .orderedDescending)
    }

    @Test func publishedPolicyMatchesTheEmbeddedPublicKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data(base64Encoded:
            "BFJtmjTmd1rDBULsDC8N2uUduNcBYG1pZlV4ZWUv7ye4ep58ZqTUqH0020/dUD4gLclfvglE8JD3F0XujaDm5PE="
        )!)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains(publicKey.x963Representation.base64EncodedString()))
        #expect(project.contains("https://raw.githubusercontent.com/carlosrebato/ai-usage-mac/main/remote-policy.json"))
        let policy = try ProviderKillSwitch.verify(
            Data(contentsOf: root.appendingPathComponent("remote-policy.json")),
            publicKey: publicKey
        )
        #expect(policy.disabledProviders.isEmpty)
        #expect(policy.minimumVersion == nil)
        #expect(policy.expiresAt > policy.issuedAt)
    }

    @Test func signedRemotePolicyStopsOnlyTheChosenDirectProvider() async throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 900)
        let policy = ProviderKillSwitch.Policy(
            schemaVersion: 1,
            disabledProviders: [.claude],
            minimumVersion: nil,
            notice: "Claude paused",
            issuedAt: Date(timeIntervalSince1970: 800),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let payload = try JSONEncoder().encode(policy)
        let signature = try key.signature(for: payload).derRepresentation
        let url = URL(string: "https://example.com/remote-policy-\(UUID().uuidString).json")!
        let responseData = try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(),
            "signature": signature.base64EncodedString()
        ])
        PolicyURLProtocol.register(responseData, for: url)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PolicyURLProtocol.self]
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let switcher = ProviderKillSwitch(
            session: URLSession(configuration: sessionConfiguration),
            defaults: defaults,
            now: { now },
            configuration: .init(
                url: url,
                publicKey: key.publicKey
            )
        )

        await #expect(throws: ProviderPolicyError.self) {
            try await switcher.check(.claude)
        }
        try await switcher.check(.codex)
        #expect(await switcher.currentNotice() == "Claude paused")
    }

    @Test func forgedRemotePolicyIsIgnored() async throws {
        let trustedKey = P256.Signing.PrivateKey()
        let attackerKey = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 900)
        let policy = ProviderKillSwitch.Policy(
            schemaVersion: 1,
            disabledProviders: [.codex],
            minimumVersion: nil,
            notice: "Forged pause",
            issuedAt: Date(timeIntervalSince1970: 800),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let payload = try JSONEncoder().encode(policy)
        let signature = try attackerKey.signature(for: payload).derRepresentation
        let url = URL(string: "https://example.com/remote-policy-\(UUID().uuidString).json")!
        let responseData = try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(),
            "signature": signature.base64EncodedString()
        ])
        PolicyURLProtocol.register(responseData, for: url)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PolicyURLProtocol.self]
        let switcher = ProviderKillSwitch(
            session: URLSession(configuration: sessionConfiguration),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            now: { now },
            configuration: .init(
                url: url,
                publicKey: trustedKey.publicKey
            )
        )

        try await switcher.check(.codex)
        #expect(await switcher.currentNotice() == nil)
    }
}
