import AIUsageCore
import CommonCrypto
import CryptoKit
import Dispatch
import Foundation
import LocalAuthentication
import Security

enum ClaudeDesktopCredentialStatus: Equatable, Sendable {
    case available(ClaudeCredential)
    case notFound
    case dataAccessRequired
    case keychainPermissionRequired
    case stale
    case invalid
}

protocol ClaudeDesktopCredentialReading: Sendable {
    func cachedCredential(now: Date) -> ClaudeCredential?
    func load(allowInteraction: Bool, now: Date) -> ClaudeDesktopCredentialStatus
}

final class ClaudeDesktopCredentialReader: ClaudeDesktopCredentialReading, @unchecked Sendable {
    private static let service = "Claude Safe Storage"
    private static let account = "Claude Key"
    private static let apiHost = "https://api.anthropic.com"
    private static let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let directDataRoot: URL?
    private let dataAccess: ClaudeDesktopDataAccess?
    private let lock = NSLock()
    private var cachedKey: Data?
    private var memoryCredential: ClaudeCredential?

    init(dataAccess: ClaudeDesktopDataAccess = .shared) {
        directDataRoot = nil
        self.dataAccess = dataAccess
    }

    init(homeDirectory: URL) {
        directDataRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        dataAccess = nil
    }

    func hasCredentialMaterial() -> Bool {
        guard let dataRoot = dataRootURL else { return false }
        let didStartAccess = dataRoot.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { dataRoot.stopAccessingSecurityScopedResource() }
        }
        return hasCredentialMaterial(in: dataRoot)
    }

    private func hasCredentialMaterial(in dataRoot: URL) -> Bool {
        guard
            let root = configRoot(in: dataRoot),
            root["oauth:tokenCacheV2"] is String || root["oauth:tokenCache"] is String
        else { return false }
        return cookieURLs(in: dataRoot).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    func load(allowInteraction: Bool, now: Date) -> ClaudeDesktopCredentialStatus {
        if let credential = cachedCredential(now: now) {
            return .available(credential)
        }
        guard let dataRoot = dataRootURL else { return .dataAccessRequired }
        let didStartAccess = dataRoot.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { dataRoot.stopAccessingSecurityScopedResource() }
        }
        guard hasCredentialMaterial(in: dataRoot) else { return .notFound }

        do {
            guard let key = try safeStorageKey(allowInteraction: allowInteraction) else {
                return .notFound
            }
            guard let organization = try activeOrganization(key: key, dataRoot: dataRoot),
                  let root = configRoot(in: dataRoot)
            else { return .invalid }

            let v2 = try decodedCache(root["oauth:tokenCacheV2"], key: key)
            let v1 = try decodedCache(root["oauth:tokenCache"], key: key)
            let status = Self.selectCredential(
                organization: organization,
                v2: v2,
                v1: v1,
                now: now
            )
            if case .available(let credential) = status {
                lock.withLock { memoryCredential = credential }
            }
            return status
        } catch ClaudeDesktopReadError.permissionRequired {
            return .keychainPermissionRequired
        } catch {
            return .invalid
        }
    }

    func cachedCredential(now: Date) -> ClaudeCredential? {
        lock.withLock {
            guard let credential = memoryCredential else { return nil }
            if let expiresAt = credential.expiresAt,
               expiresAt <= now.timeIntervalSince1970 * 1000 + 60_000 {
                memoryCredential = nil
                return nil
            }
            return credential
        }
    }

    static func selectCredential(
        organization: String,
        v2: [String: Any]?,
        v1: [String: Any]?,
        now: Date
    ) -> ClaudeDesktopCredentialStatus {
        let normalizedOrganization = organization.lowercased()
        let v2Selection = candidates(in: v2, organization: normalizedOrganization, now: now)
        if let best = v2Selection.available.max(by: { $0.hasLowerPriority(than: $1) }) {
            return .available(best.credential)
        }

        let v2Keys: Set<String> = v2.map { Set($0.keys) } ?? []
        let remainingV1 = v1?.filter { !v2Keys.contains($0.key) }
        let v1Selection = candidates(in: remainingV1, organization: normalizedOrganization, now: now)
        if let best = v1Selection.available.max(by: { $0.hasLowerPriority(than: $1) }) {
            return .available(best.credential)
        }
        if v2Selection.sawStale || v1Selection.sawStale { return .stale }
        if v2Selection.sawInvalid || v1Selection.sawInvalid { return .invalid }
        return .notFound
    }

    static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let status = key.withUnsafeMutableBytes { output in
            passwordData.withUnsafeBytes { password in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        salt.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        output.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeDesktopReadError.invalidKey }
        return key
    }

    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3,
              key.count == kCCKeySizeAES128
        else { throw ClaudeDesktopReadError.invalidCiphertext }

        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeDesktopReadError.decryptionFailed }
        output.count = outputLength
        return output
    }

    private var dataRootURL: URL? {
        directDataRoot ?? dataAccess?.resolvedURL()
    }

    private func cookieURLs(in dataRoot: URL) -> [URL] {
        ["Cookies", "Network/Cookies"].map {
            dataRoot.appendingPathComponent($0)
        }
    }

    private func configRoot(in dataRoot: URL) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: dataRoot.appendingPathComponent("config.json")),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    private func safeStorageKey(allowInteraction: Bool) throws -> Data? {
        if let cached = lock.withLock({ cachedKey }) { return cached }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        let context = LAContext()
        context.localizedReason =
            AppLanguage.current.text(
                "AI Usage needs to read the local Claude Desktop key to check your limits.",
                "AI Usage necesita leer la clave local de Claude Desktop para consultar tus límites."
            )
        if !allowInteraction {
            context.interactionNotAllowed = true
        }
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8), !password.isEmpty
            else { throw ClaudeDesktopReadError.invalidKey }
            let key = try Self.deriveKey(password: password)
            lock.withLock { cachedKey = key }
            return key
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw ClaudeDesktopReadError.permissionRequired
        default:
            throw ClaudeDesktopReadError.keychainFailure
        }
    }

    private func activeOrganization(key: Data, dataRoot: URL) throws -> String? {
        for url in cookieURLs(in: dataRoot) where FileManager.default.fileExists(atPath: url.path) {
            for host in [".claude.ai", "claude.ai"] {
                guard let encoded = sqliteCookieValue(database: url, host: host),
                      let separator = encoded.firstIndex(of: ":"),
                      let stored = Data(hexString: String(encoded[encoded.index(after: separator)...]))
                else { continue }

                let mode = String(encoded[..<separator])
                let value: Data
                if mode == "plain" {
                    value = stored
                } else if mode == "encrypted" {
                    let decrypted = try Self.decrypt(stored, key: key)
                    let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
                    guard decrypted.starts(with: hostHash) else { continue }
                    value = decrypted.dropFirst(hostHash.count)
                } else {
                    continue
                }

                guard let organization = String(data: value, encoding: .utf8),
                      UUID(uuidString: organization) != nil
                else { continue }
                return organization.lowercased()
            }
        }
        return nil
    }

    private func sqliteCookieValue(database: URL, host: String) -> String? {
        let escapedHost = host.replacingOccurrences(of: "'", with: "''")
        let sql = """
        SELECT CASE WHEN length(value) > 0
          THEN 'plain:' || hex(CAST(value AS BLOB))
          ELSE 'encrypted:' || hex(encrypted_value) END
        FROM cookies WHERE name = 'lastActiveOrg' AND host_key = '\(escapedHost)'
        ORDER BY last_update_utc DESC LIMIT 1;
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", database.path, sql]
        process.standardOutput = output
        process.standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            guard finished.wait(timeout: .now() + .seconds(2)) == .success else {
                if process.isRunning { process.terminate() }
                _ = finished.wait(timeout: .now() + .milliseconds(250))
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        } catch {
            return nil
        }
    }

    private func decodedCache(_ stored: Any?, key: Data) throws -> [String: Any]? {
        guard let base64 = stored as? String else { return nil }
        guard let encrypted = Data(base64Encoded: base64) else {
            throw ClaudeDesktopReadError.invalidCiphertext
        }
        let plaintext = try Self.decrypt(encrypted, key: key)
        return try JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
    }

    private struct Candidate {
        let credential: ClaudeCredential
        let clientID: String
        let scopes: [String]
        let expiresAt: Double

        private var isFullScope: Bool {
            scopes.contains("user:profile") && scopes.contains("user:inference")
        }

        private var isProductionFullScope: Bool {
            clientID == ClaudeDesktopCredentialReader.productionClientID && isFullScope
        }

        func hasLowerPriority(than other: Candidate) -> Bool {
            if isProductionFullScope != other.isProductionFullScope {
                return !isProductionFullScope
            }
            if isFullScope != other.isFullScope {
                return !isFullScope
            }
            if scopes.count != other.scopes.count {
                return scopes.count < other.scopes.count
            }
            return expiresAt < other.expiresAt
        }
    }

    private static func candidates(
        in cache: [String: Any]?, organization: String, now: Date
    ) -> (available: [Candidate], sawStale: Bool, sawInvalid: Bool) {
        guard let cache else { return ([], false, false) }
        var available: [Candidate] = []
        var sawStale = false
        var sawInvalid = false

        for (key, raw) in cache {
            guard let parsed = parseCacheKey(key), parsed.organization == organization,
                  parsed.scopes.contains("user:profile")
            else { continue }
            guard !(raw is NSNull) else { continue }
            guard let entry = raw as? [String: Any],
                  let token = entry["token"] as? String, !token.isEmpty,
                  let expiresAt = (entry["expiresAt"] as? NSNumber)?.doubleValue
            else {
                sawInvalid = true
                continue
            }
            guard expiresAt > now.timeIntervalSince1970 * 1000 + 120_000 else {
                sawStale = true
                continue
            }
            available.append(Candidate(
                credential: ClaudeCredential(
                    accessToken: token,
                    expiresAt: expiresAt,
                    subscriptionType: entry["subscriptionType"] as? String,
                    rateLimitTier: entry["rateLimitTier"] as? String,
                    scopes: parsed.scopes
                ),
                clientID: parsed.clientID,
                scopes: parsed.scopes,
                expiresAt: expiresAt
            ))
        }
        return (available, sawStale, sawInvalid)
    }

    private static func parseCacheKey(_ value: String) -> (
        clientID: String, organization: String, scopes: [String]
    )? {
        let marker = ":\(apiHost):"
        guard let markerRange = value.range(of: marker) else { return nil }
        let prefix = value[..<markerRange.lowerBound]
        guard let colon = prefix.firstIndex(of: ":") else { return nil }
        let clientID = String(prefix[..<colon])
        let organization = String(prefix[prefix.index(after: colon)...]).lowercased()
        guard UUID(uuidString: clientID) != nil, UUID(uuidString: organization) != nil else { return nil }
        let scopes = value[markerRange.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
        return (clientID, organization, scopes)
    }
}

private enum ClaudeDesktopReadError: Error {
    case permissionRequired
    case invalidKey
    case invalidCiphertext
    case decryptionFailed
    case keychainFailure
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
