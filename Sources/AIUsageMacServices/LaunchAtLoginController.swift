import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
public final class LaunchAtLoginController: ObservableObject {
    @Published public private(set) var status: LaunchAtLoginStatus
    @Published public private(set) var errorMessage: String?

    private let service: any LaunchAtLoginServicing

    public convenience init() {
        self.init(service: SystemLaunchAtLoginService())
    }

    init(service: any LaunchAtLoginServicing) {
        self.service = service
        status = service.status
    }

    public var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            status = service.status
        } catch {
            status = service.status
            errorMessage = error.localizedDescription
        }
    }

    public func refresh() {
        status = service.status
    }

    public func openSystemSettings() {
        service.openSystemSettings()
    }
}
