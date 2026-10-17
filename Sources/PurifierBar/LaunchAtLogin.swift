// Launch at login via SMAppService. Unavailable outside the bundle,
// so all calls are guarded by an `isBundled` check.
import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    /// Whether the app runs as a real bundle (required for SMAppService).
    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// The real registration state in the system.
    static var isEnabled: Bool {
        guard isBundled else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// The system is waiting for the user's confirmation in settings.
    static var requiresApproval: Bool {
        guard isBundled else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// Registers or unregisters launch at login. Returns the error to the caller - the UI shows it as text.
    static func setEnabled(_ enabled: Bool) throws {
        guard isBundled else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettingsLoginItems() {
        guard isBundled else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
