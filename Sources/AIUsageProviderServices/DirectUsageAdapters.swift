import AIUsageCore
import Foundation

public enum DirectUsageError: LocalizedError, Equatable, Sendable {
    case notAuthenticated
    case accountIdentifierMissing
    case timedOut
    case rateLimited(retryAfter: TimeInterval?)
    case rejected(status: Int)
    case malformedResponse
    case missingUsageWindows
    case transport

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to continue."
        case .accountIdentifierMissing: "The account identifier is missing. Sign in again."
        case .timedOut: "The provider took too long to respond."
        case .rateLimited(let delay):
            delay.map { "Updates are limited. Retry in \(Int(ceil($0 / 60))) min." }
                ?? "Updates are temporarily limited."
        case .rejected(let status): "The provider returned HTTP \(status)."
        case .malformedResponse: "The provider returned an unknown response."
        case .missingUsageWindows: "The provider did not return usage limits."
        case .transport: "The provider could not be reached."
        }
    }

    public var retryAfter: TimeInterval? {
        guard case .rateLimited(let value) = self else { return nil }
        return value
    }

    public var requiresReauthentication: Bool {
        switch self {
        case .notAuthenticated, .accountIdentifierMissing, .rejected(status: 401),
             .rejected(status: 403): true
        default: false
        }
    }
}

public protocol DirectUsageAdapter: Sendable {
    var providerID: UsageProviderID { get }
    func fetchSnapshot() async throws -> ProviderUsageSnapshot
}

public actor ClaudeDirectAdapter: DirectUsageAdapter {
    public nonisolated let providerID = UsageProviderID.claude

    private let account: ProviderOAuthAccount
    private let session: URLSession
    private let endpoint: URL
    private let profileEndpoint: URL
    private let now: @Sendable () -> Date
    private var rateLimitedUntil: Date?
    private var cachedPlan: String?

    public init(
        account: ProviderOAuthAccount = ProviderAccounts.shared.claude,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        profileEndpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/profile")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.account = account
        self.session = session
        self.endpoint = endpoint
        self.profileEndpoint = profileEndpoint
        self.now = now
    }

    public func fetchSnapshot() async throws -> ProviderUsageSnapshot {
        try await ProviderKillSwitch.shared.check(.claude)
        if let rateLimitedUntil, now() < rateLimitedUntil {
            throw DirectUsageError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSince(now()))
        }
        guard let credential = try await account.credential() else {
            throw DirectUsageError.notAuthenticated
        }
        // This is the blocking viability invariant: no inference/API-key scope.
        guard credential.scopes == ["user:profile"] else {
            throw DirectUsageError.notAuthenticated
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AIUsage/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.perform(request, session: session)
        switch response.statusCode {
        case 200:
            rateLimitedUntil = nil
            let plan: String?
            if let cachedPlan {
                plan = cachedPlan
            } else {
                plan = await fetchProfilePlan(accessToken: credential.accessToken)
            }
            cachedPlan = plan
            return try ClaudeDirectUsageNormalizer.snapshot(
                from: data,
                plan: plan,
                observedAt: now()
            )
        case 401, 403:
            throw DirectUsageError.rejected(status: response.statusCode)
        case 429:
            let retry = max(Self.retryAfter(from: response, now: now()) ?? 0, 5 * 60)
            rateLimitedUntil = now().addingTimeInterval(retry)
            throw DirectUsageError.rateLimited(retryAfter: retry)
        default:
            throw DirectUsageError.rejected(status: response.statusCode)
        }
    }

    private static func perform(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DirectUsageError.malformedResponse
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw DirectUsageError.timedOut
        } catch let error as DirectUsageError {
            throw error
        } catch {
            throw DirectUsageError.transport
        }
    }

    private static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        HTTPRetryAfter.value(from: response, now: now)
    }

    private func fetchProfilePlan(accessToken: String) async -> String? {
        var request = URLRequest(url: profileEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AIUsage/0.1", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await Self.perform(request, session: session),
              response.statusCode == 200
        else { return nil }
        return ClaudeProfileNormalizer.plan(from: data)
    }
}

public actor CodexDirectAdapter: DirectUsageAdapter {
    public nonisolated let providerID = UsageProviderID.codex

    private let account: ProviderOAuthAccount
    private let session: URLSession
    private let endpoint: URL
    private let now: @Sendable () -> Date
    private var rateLimitedUntil: Date?

    public init(
        account: ProviderOAuthAccount = ProviderAccounts.shared.codex,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.account = account
        self.session = session
        self.endpoint = endpoint
        self.now = now
    }

    public func fetchSnapshot() async throws -> ProviderUsageSnapshot {
        try await ProviderKillSwitch.shared.check(.codex)
        if let rateLimitedUntil, now() < rateLimitedUntil {
            throw DirectUsageError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSince(now()))
        }
        guard let credential = try await account.credential() else {
            throw DirectUsageError.notAuthenticated
        }
        guard let accountID = credential.accountID, !accountID.isEmpty else {
            throw DirectUsageError.accountIdentifierMissing
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200:
            rateLimitedUntil = nil
            return try CodexDirectUsageNormalizer.snapshot(from: data, observedAt: now())
        case 401, 403:
            throw DirectUsageError.rejected(status: response.statusCode)
        case 429:
            let retry = max(HTTPRetryAfter.value(from: response, now: now()) ?? 0, 5 * 60)
            rateLimitedUntil = now().addingTimeInterval(retry)
            throw DirectUsageError.rateLimited(retryAfter: retry)
        default:
            throw DirectUsageError.rejected(status: response.statusCode)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DirectUsageError.malformedResponse
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw DirectUsageError.timedOut
        } catch let error as DirectUsageError {
            throw error
        } catch {
            throw DirectUsageError.transport
        }
    }
}

public enum ClaudeDirectUsageNormalizer {
    public static func snapshot(
        from data: Data,
        plan: String? = nil,
        observedAt: Date
    ) throws -> ProviderUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectUsageError.malformedResponse
        }
        let session = window(root["five_hour"])
        let weekly = window(root["seven_day"])
        guard session.usedPercent != nil || weekly.usedPercent != nil else {
            throw DirectUsageError.missingUsageWindows
        }
        return ProviderUsageSnapshot(
            id: .claude,
            session: session,
            weekly: weekly,
            observedAt: observedAt,
            source: .live,
            message: plan.map { "Plan \($0)" } ?? "Connected"
        )
    }

    private static func window(_ object: Any?) -> UsageWindow {
        guard let dictionary = object as? [String: Any] else {
            return UsageWindow(usedPercent: nil, resetsAt: nil)
        }
        let value = (dictionary["utilization"] as? NSNumber)?.doubleValue
        let reset = ProviderTimestamp.date(from: dictionary["resets_at"])
        return UsageWindow(
            usedPercent: value.map { min(max($0, 0), 100) },
            resetsAt: reset
        )
    }
}

public enum CodexDirectUsageNormalizer {
    public static func snapshot(from data: Data, observedAt: Date) throws -> ProviderUsageSnapshot {
        let response: CodexUsageResponse
        do {
            response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            throw DirectUsageError.malformedResponse
        }
        guard let limits = response.rateLimit else { throw DirectUsageError.missingUsageWindows }
        let windows = [limits.primaryWindow, limits.secondaryWindow].compactMap { $0 }
        let weekly = windows.first { ($0.limitWindowSeconds ?? 0) >= 7 * 24 * 60 * 60 }
        let session = weekly == nil ? limits.primaryWindow : windows.first { $0 != weekly }
        let fallbackWeekly = weekly
            ?? (limits.primaryWindow == session ? limits.secondaryWindow : limits.primaryWindow)
        guard session?.usedPercent != nil || fallbackWeekly?.usedPercent != nil else {
            throw DirectUsageError.missingUsageWindows
        }
        return ProviderUsageSnapshot(
            id: .codex,
            session: window(session),
            weekly: window(fallbackWeekly),
            observedAt: observedAt,
            source: .live,
            message: response.planType.map { "Plan \($0.capitalized)" } ?? "Connected"
        )
    }

    private static func window(_ value: CodexRateLimitWindow?) -> UsageWindow {
        UsageWindow(
            usedPercent: value?.usedPercent.map { min(max($0, 0), 100) },
            resetsAt: value?.resetAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

public enum ClaudeProfileNormalizer {
    public static func plan(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        let tier = organization?["rate_limit_tier"] as? String
        let organizationType = organization?["organization_type"] as? String

        if let tier,
           let multiplier = tier.range(of: #"\d+x"#, options: .regularExpression) {
            return "Max \(tier[multiplier])"
        }
        if organizationType == "claude_max" || account?["has_claude_max"] as? Bool == true {
            return "Max"
        }
        if organizationType == "claude_pro" || account?["has_claude_pro"] as? Bool == true {
            return "Pro"
        }
        if let organizationType,
           let suffix = organizationType.split(separator: "_").last,
           ["team", "enterprise"].contains(suffix) {
            return suffix.capitalized
        }
        return nil
    }
}

private enum ProviderTimestamp {
    static func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private enum HTTPRetryAfter {
    static func value(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
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

private struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateLimitWindow?
    let secondaryWindow: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexRateLimitWindow: Decodable, Equatable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}
