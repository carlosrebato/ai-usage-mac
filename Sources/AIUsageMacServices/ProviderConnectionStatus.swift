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
    public let dataState: ProviderDataState
    public let message: String

    public init(
        id: UsageProviderID,
        phase: ProviderConnectionPhase,
        dataState: ProviderDataState? = nil,
        message: String
    ) {
        self.id = id
        self.phase = phase
        self.dataState = dataState ?? Self.defaultState(for: phase)
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

    private static func defaultState(for phase: ProviderConnectionPhase) -> ProviderDataState {
        switch phase {
        case .connected: .live
        case .actionRequired(.signIn): .reauthRequired
        case .checking, .actionRequired, .retrying: .temporarilyUnavailable
        }
    }
}

/// Snapshot and connection metadata are published as one value so observers
/// can never render a new connection phase with an old provider snapshot (or
/// the inverse).
public struct ProviderRuntimeState: Identifiable, Equatable, Sendable {
    public let id: UsageProviderID
    public var snapshot: ProviderUsageSnapshot
    public var connection: ProviderConnectionStatus?

    init(
        id: UsageProviderID,
        snapshot: ProviderUsageSnapshot,
        connection: ProviderConnectionStatus?
    ) {
        precondition(snapshot.id == id)
        precondition(connection == nil || connection?.id == id)
        self.id = id
        self.snapshot = snapshot
        self.connection = connection
    }
}
