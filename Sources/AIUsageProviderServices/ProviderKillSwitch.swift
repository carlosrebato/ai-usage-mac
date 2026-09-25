import AIUsageCore
import CryptoKit
import Foundation

public enum ProviderPolicyError: LocalizedError, Equatable, Sendable {
    case providerDisabled(UsageProviderID, notice: String?)
    case minimumVersionRequired(String, notice: String?)

    public var errorDescription: String? {
        switch self {
        case .providerDisabled(let provider, let notice):
            notice ?? "\(provider.displayName) is temporarily disabled for safety."
        case .minimumVersionRequired(let version, let notice):
            notice ?? "AI Usage \(version) or later is required."
        }
    }
}

public actor ProviderKillSwitch {
    public static let shared = ProviderKillSwitch()

    private let session: URLSession
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let configuration: Configuration?
    private var policy: Policy?
    private var loaded = false
    private var refreshTask: Task<Void, Never>?

    public init() {
        session = .shared
        defaults = .standard
        now = Date.init
        configuration = Configuration.fromBundle()
    }

    init(
        session: URLSession,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> Date,
        configuration: Configuration?
    ) {
        self.session = session
        self.defaults = defaults
        self.now = now
        self.configuration = configuration
    }

    public func check(_ provider: UsageProviderID) async throws {
        loadCacheOnce()
        await refreshIfDue()
        guard let policy, policy.expiresAt > now() else { return }
        if let minimum = policy.minimumVersion,
           Self.compareVersions(Self.currentVersion, minimum) == .orderedAscending {
            throw ProviderPolicyError.minimumVersionRequired(minimum, notice: policy.notice)
        }
        if policy.disabledProviders.contains(provider) {
            throw ProviderPolicyError.providerDisabled(provider, notice: policy.notice)
        }
    }

    public func currentNotice() -> String? {
        loadCacheOnce()
        guard let policy, policy.expiresAt > now() else { return nil }
        return policy.notice
    }

    private func refreshIfDue() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard let configuration else { return }
        let lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard now().timeIntervalSince(lastCheck) >= 24 * 60 * 60 else { return }
        // Mark before the request so a failing endpoint cannot create a polling loop.
        defaults.set(now(), forKey: Keys.lastCheck)
        let task = Task { await fetchPolicy(from: configuration) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func fetchPolicy(from configuration: Configuration) async {
        do {
            var request = URLRequest(url: configuration.url)
            request.timeoutInterval = 4
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  data.count <= 16 * 1024 else { return }
            let verified = try Self.verify(data, publicKey: configuration.publicKey)
            policy = verified
            defaults.set(try JSONEncoder().encode(verified), forKey: Keys.policy)
        } catch {
            // Availability of the remote file must never hide last-known usage.
        }
    }

    private func loadCacheOnce() {
        guard !loaded else { return }
        loaded = true
        guard let data = defaults.data(forKey: Keys.policy) else { return }
        policy = try? JSONDecoder().decode(Policy.self, from: data)
    }

    static func verify(_ data: Data, publicKey: P256.Signing.PublicKey) throws -> Policy {
        let envelope = try JSONDecoder().decode(SignedEnvelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signatureData = Data(base64Encoded: envelope.signature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: payload)
        else { throw VerificationError.invalidSignature }
        let policy = try JSONDecoder().decode(Policy.self, from: payload)
        guard policy.schemaVersion == 1 else { throw VerificationError.unsupportedSchema }
        return policy
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Configuration: Sendable {
        let url: URL
        let publicKey: P256.Signing.PublicKey

        static func fromBundle(_ bundle: Bundle = .main) -> Configuration? {
            guard let rawURL = bundle.object(forInfoDictionaryKey: "AIUsageRemoteConfigURL") as? String,
                  let url = URL(string: rawURL), url.scheme == "https",
                  let rawKey = bundle.object(forInfoDictionaryKey: "AIUsageRemoteConfigPublicKey") as? String,
                  let keyData = Data(base64Encoded: rawKey),
                  let key = try? P256.Signing.PublicKey(x963Representation: keyData)
            else { return nil }
            return Configuration(url: url, publicKey: key)
        }
    }

    struct Policy: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let disabledProviders: Set<UsageProviderID>
        let minimumVersion: String?
        let notice: String?
        let issuedAt: Date
        let expiresAt: Date
    }

    private struct SignedEnvelope: Codable {
        let payload: String
        let signature: String
    }

    private enum VerificationError: Error {
        case invalidSignature
        case unsupportedSchema
    }

    private enum Keys {
        static let lastCheck = "AIUsage.RemotePolicy.LastCheck.v1"
        static let policy = "AIUsage.RemotePolicy.Verified.v1"
    }
}
