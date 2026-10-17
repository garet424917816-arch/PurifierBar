// Launching the settings window in a separate process. The main process never
// creates `SettingsView`: after the window closes the settings process exits,
// and allocator fragmentation and system caches do not settle in the main one (T11).
import AppKit
import Foundation

@MainActor
final class SettingsLauncher {
    private var process: Process?

    /// Open the settings window: close the panel, then raise the existing
    /// settings process or start a new one.
    func open() {
        // The gear click comes from the MenuBarExtra panel - it is the key window now;
        // we close it so it does not stay on top of the settings.
        NSApp.keyWindow?.close()

        if let process, process.isRunning {
            SettingsSync.post(.show)
            return
        }

        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--settings"]
        // `terminationHandler` is called on a work queue - further work happens on the main
        // actor. We clear only our own process: otherwise a late cleanup of the old
        // process would wipe the reference to the newly started one.
        child.terminationHandler = { [weak self] ended in
            let pid = ended.processIdentifier
            // Closing the window and "Quit" give code 0; anything else - the process crashed.
            let crashed = ended.terminationReason == .uncaughtSignal || ended.terminationStatus != 0
            let status = ended.terminationStatus
            Task { @MainActor in
                guard let self, self.process?.processIdentifier == pid else { return }
                self.process = nil
                if crashed {
                    Self.reportFailure(String(localized: "The settings process failed (code \(status))."))
                }
            }
        }
        do {
            try child.run()
            process = child
        } catch {
            // Without this the gear silently does nothing - for example, when
            // the binary the app was launched from has been deleted from disk.
            process = nil
            Self.reportFailure(error.localizedDescription)
        }
    }

    /// Opening the settings failed - a short message instead of silence.
    private static func reportFailure(_ details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not open settings")
        alert.informativeText = details + String(localized: "\nRestart Purifier Bar. If that does not help, reinstall it.")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
