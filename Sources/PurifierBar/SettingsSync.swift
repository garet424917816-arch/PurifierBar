// Shared contract between the main process and the settings process: the names of
// distributed notifications and the keys the processes exchange. Data flows only through
// the settings file, `UserDefaults` and Keychain - `userInfo` is not used.
import Foundation

enum SettingsSync {
    /// Distributed notification names - in one place.
    enum Name: String {
        /// Settings changed in the window: the main process rereads the file.
        case settingsChanged = "local.purifierbar.settingsChanged"
        /// Token saved in Keychain: the main process reconnects without a payload.
        case tokenChanged = "local.purifierbar.tokenChanged"
        /// Schedule changed in the panel: the settings process rereads the file.
        case automationChanged = "local.purifierbar.automationChanged"
        /// Bring the settings window to the foreground.
        case show = "local.purifierbar.show"
        /// Quit the app completely.
        case quit = "local.purifierbar.quit"
    }

    // MARK: - Shared keys

    /// The `UserDefaults` key with the device IP - shared by both processes.
    static let hostKey = "host"
    /// Maximum manual/boost level of the last authenticated device.
    static let favoriteLevelMaximumKey = "favoriteLevelMaximum"
    /// No default IP: until a device answers, the first connection searches the network by broadcast.
    static let defaultHost = ""

    // MARK: - Exchange

    /// Subscription on the main queue; the body runs on the main actor.
    static func observe(
        _ name: Name,
        _ handler: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name.rawValue),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Send a notification to all processes of the app.
    static func post(_ name: Name) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name.rawValue),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
