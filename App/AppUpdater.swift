#if canImport(Sparkle)
import Sparkle

@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#else
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private init() {}

    func checkForUpdates() {}
}
#endif
