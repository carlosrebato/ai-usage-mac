import AIUsageCore
import Foundation

public struct UsageDiagnosticReport: Codable, Sendable {
    public struct Provider: Codable, Sendable {
        public let id: UsageProviderID
        public let phase: String
        public let dataState: ProviderDataState
        public let source: UsageSource
        public let hasQuotaData: Bool
        public let hasLocalTotals: Bool
        public let observedAt: Date
        public let observationAgeSeconds: Int
        public let consecutiveFailures: Int
        public let nextRefreshInSeconds: Int
        public let isVerifyingAuthorization: Bool
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let operatingSystem: String
    public let providers: [Provider]
    public let retainedHistoryDays: Int
}

extension ProviderConnectionPhase {
    var diagnosticName: String {
        switch self {
        case .checking: "checking"
        case .connected: "connected"
        case .retrying: "retrying"
        case .actionRequired(.grantPermission): "action-required:grant-permission"
        case .actionRequired(.signIn): "action-required:sign-in"
        case .actionRequired(.install): "action-required:install"
        case .actionRequired(.retry): "action-required:retry"
        }
    }
}
