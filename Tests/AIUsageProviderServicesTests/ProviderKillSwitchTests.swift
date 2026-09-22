import CryptoKit
import Foundation
import Testing
import AIUsageCore
@testable import AIUsageProviderServices

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
}
