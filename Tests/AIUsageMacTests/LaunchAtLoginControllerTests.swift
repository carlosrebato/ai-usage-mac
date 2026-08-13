import Foundation
import Testing
@testable import AIUsageMacServices

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus = .disabled
    var nextError: Error?
    var openedSystemSettings = false

    func register() throws {
        if let nextError { throw nextError }
        status = .enabled
    }

    func unregister() throws {
        if let nextError { throw nextError }
        status = .disabled
    }

    func openSystemSettings() {
        openedSystemSettings = true
    }
}

struct LaunchAtLoginControllerTests {
    @Test @MainActor func togglesTheNativeLoginItem() {
        let service = FakeLaunchAtLoginService()
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)

        controller.setEnabled(false)
        #expect(controller.status == .disabled)
        #expect(!controller.isEnabled)
    }

    @Test @MainActor func preservesSystemStateWhenRegistrationFails() {
        let service = FakeLaunchAtLoginService()
        service.nextError = TestLaunchError.denied
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(controller.status == .disabled)
        #expect(controller.errorMessage != nil)
    }
}

private enum TestLaunchError: LocalizedError {
    case denied

    var errorDescription: String? { "Registro rechazado" }
}
