import AIUsageCore
import Foundation

public enum ProviderSetupAction: Equatable, Sendable {
    case grantPermission
    case signIn
    case install
    case retry
}

public enum ProviderConnectionPhase: Equatable, Sendable {
    case checking
    case connected
    case actionRequired(ProviderSetupAction)
    case retrying
}

public struct ProviderConnectionStatus: Identifiable, Equatable, Sendable {
    public let id: UsageProviderID
    public let phase: ProviderConnectionPhase
    public let message: String

    public init(id: UsageProviderID, phase: ProviderConnectionPhase, message: String) {
        self.id = id
        self.phase = phase
        self.message = message
    }

    public var isConnected: Bool {
        phase == .connected
    }

    public var action: ProviderSetupAction? {
        switch phase {
        case .actionRequired(let action): action
        case .retrying: .retry
        case .checking, .connected: nil
        }
    }
}
