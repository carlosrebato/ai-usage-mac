#if canImport(Sparkle)
import Sparkle

@MainActor
private final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: AppPreferenceKey.receiveBetaUpdates) ? ["beta"] : []
    }
}

@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private let channelDelegate = UpdateChannelDelegate()
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channelDelegate,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updateChannelSelection() {
        controller.updater.resetUpdateCycleAfterShortDelay()
    }
}
#else
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private init() {}

    func checkForUpdates() {}
    func updateChannelSelection() {}
}
#endif
