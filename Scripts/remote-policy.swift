#!/usr/bin/env swift

import CryptoKit
import Foundation
import Security

// The private signing key is device-only Keychain data. Never put it in Git,
// CI logs, an environment variable or an app bundle.
private let keychainService = "com.carlosrebato.aiusage.remote-policy-signing"
private let keychainAccount = "v1"

private struct Policy: Codable {
    let schemaVersion: Int
    let disabledProviders: [String]
    let minimumVersion: String?
    let notice: String?
    let issuedAt: Date
    let expiresAt: Date
}

private struct SignedEnvelope: Codable {
    let payload: String
    let signature: String
}

private func keychainQuery() -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount
    ]
}

private func loadKey() throws -> P256.Signing.PrivateKey {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw NSError(domain: "RemotePolicy", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Signing key not found in the local Keychain. Run create-key once."
        ])
    }
    return try P256.Signing.PrivateKey(rawRepresentation: data)
}

private func createKey() throws {
    let key = P256.Signing.PrivateKey()
    var item = keychainQuery()
    item[kSecValueData as String] = key.rawRepresentation
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw NSError(domain: "RemotePolicy", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: status == errSecDuplicateItem
                ? "A signing key already exists; refusing to overwrite it."
                : "Could not save the signing key in Keychain (status \(status))."
        ])
    }
    print(key.publicKey.x963Representation.base64EncodedString())
}

private func sign(source: URL, destination: URL) throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let policy = try decoder.decode(Policy.self, from: Data(contentsOf: source))
    guard policy.schemaVersion == 1,
          Set(policy.disabledProviders).isSubset(of: ["claude", "codex"]),
          policy.expiresAt > policy.issuedAt,
          policy.expiresAt > Date(),
          policy.expiresAt.timeIntervalSince(policy.issuedAt) <= 30 * 24 * 60 * 60,
          (policy.notice?.count ?? 0) <= 300
    else {
        throw NSError(domain: "RemotePolicy", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Invalid policy: use known providers and a future expiry within 30 days."
        ])
    }
    let payload = try JSONEncoder().encode(policy)
    let signature = try loadKey().signature(for: payload).derRepresentation
    let envelope = SignedEnvelope(
        payload: payload.base64EncodedString(),
        signature: signature.base64EncodedString()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(envelope)
    data.append(0x0A)
    try data.write(to: destination, options: .atomic)
    print("Signed policy written to \(destination.path)")
}

private func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["create-key"] {
        try createKey()
    } else if args == ["public-key"] {
        print(try loadKey().publicKey.x963Representation.base64EncodedString())
    } else if args.count == 3, args[0] == "sign" {
        try sign(source: URL(fileURLWithPath: args[1]), destination: URL(fileURLWithPath: args[2]))
    } else {
        throw NSError(domain: "RemotePolicy", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Usage: swift Scripts/remote-policy.swift create-key | public-key | sign SOURCE.json DESTINATION.json"
        ])
    }
}

do {
    try run()
} catch {
    fputs("Remote policy: \(error.localizedDescription)\n", stderr)
    exit(1)
}
