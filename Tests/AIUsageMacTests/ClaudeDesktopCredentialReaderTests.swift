import CommonCrypto
import Foundation
import Testing
import AIUsageCore
@testable import AIUsageMacServices

struct ClaudeDesktopCredentialReaderTests {
    private let organization = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let productionClient = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func decryptsElectronSafeStoragePayload() throws {
        let key = try ClaudeDesktopCredentialReader.deriveKey(password: "fixture-password")
        let plaintext = Data(#"{"token":"desktop-token"}"#.utf8)
        let encrypted = try encrypt(plaintext, key: key)

        #expect(try ClaudeDesktopCredentialReader.decrypt(encrypted, key: key) == plaintext)
    }

    @Test func selectsTheActiveOrganizationAndFullScopeLogin() {
        let profileOnly = cacheKey(client: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", scopes: "user:profile")
        let production = cacheKey(client: productionClient, scopes: "user:profile user:inference")
        let cache: [String: Any] = [
            profileOnly: entry(token: "old-token", expiresIn: 86_400, tier: "default_claude_max_5x"),
            production: entry(token: "current-token", expiresIn: 3_600, tier: "default_claude_max_20x")
        ]

        let result = ClaudeDesktopCredentialReader.selectCredential(
            organization: organization,
            v2: cache,
            v1: nil,
            now: now
        )

        guard case .available(let credential) = result else {
            Issue.record("Se esperaba una credencial disponible")
            return
        }
        #expect(credential.accessToken == "current-token")
        #expect(credential.displayPlan == "Max 20x")
    }

    @Test func expiredDesktopLoginIsStale() {
        let cache = [cacheKey(client: productionClient): entry(token: "expired", expiresIn: -1)]
        let result = ClaudeDesktopCredentialReader.selectCredential(
            organization: organization,
            v2: cache,
            v1: nil,
            now: now
        )
        #expect(result == .stale)
    }

    @Test func v2TombstonePreventsV1CredentialResurrection() {
        let key = cacheKey(client: productionClient)
        let result = ClaudeDesktopCredentialReader.selectCredential(
            organization: organization,
            v2: [key: NSNull()],
            v1: [key: entry(token: "old-token", expiresIn: 3_600)],
            now: now
        )
        #expect(result == .notFound)
    }

    private func cacheKey(
        client: String,
        scopes: String = "user:profile user:inference"
    ) -> String {
        "\(client):\(organization):https://api.anthropic.com:\(scopes)"
    }

    private func entry(token: String, expiresIn: TimeInterval, tier: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "token": token,
            "expiresAt": (now.timeIntervalSince1970 + expiresIn) * 1000,
            "subscriptionType": "max"
        ]
        if let tier { value["rateLimitTier"] = tier }
        return value
    }

    private func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw TestCryptoError.failed }
        output.count = outputLength
        return Data("v10".utf8) + output
    }
}

private enum TestCryptoError: Error {
    case failed
}
