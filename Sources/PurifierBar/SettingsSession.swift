// Settings window model in the settings process. Reads and writes only the settings file
// and `UserDefaults`, and stores the token in Keychain; no sockets, no `AppModel`.
import AppKit
import Foundation
import Observation
import PurifierCore

@MainActor
@Observable
final class SettingsSession {
    private(set) var settings: AutomationSettings
    private(set) var host: String
    private(set) var lastSaveError: String?
    private(set) var tokenPresent: Bool?
    private(set) var tokenSaveError: String?
    private(set) var isSavingToken = false

    private let store: SettingsStore

    init() {
        let store = SettingsStore(url: SettingsStore.defaultURL)
        self.store = store
        self.settings = store.load()
        self.host = UserDefaults.standard.string(forKey: SettingsSync.hostKey) ?? SettingsSync.defaultHost
    }

    /// Keychain work stays off the main thread and the UI receives only presence.
    func refreshTokenStatus() async {
        guard !isSavingToken, tokenPresent == nil else { return }
        let present = await Task.detached { TokenStore.hasToken() }.value
        guard !isSavingToken, tokenPresent == nil else { return }
        tokenPresent = present
    }

    func saveToken(hex: String) async -> Bool {
        guard !isSavingToken else { return false }
        isSavingToken = true
        tokenSaveError = nil
        defer { isSavingToken = false }
        do {
            try await Task.detached { try TokenStore.save(hex: hex) }.value
            tokenPresent = true
            SettingsSync.post(.tokenChanged)
            return true
        } catch MiIOError.invalidToken {
            tokenSaveError = String(localized: "Token must contain 32 hexadecimal characters")
        } catch {
            tokenSaveError = String(localized: "Could not save the token in Keychain")
        }
        return false
    }

    /// Saving automation settings: to the file and to the main process.
    func applySettings(_ newSettings: AutomationSettings) {
        settings = newSettings
        do {
            try store.save(newSettings)
            lastSaveError = nil
        } catch {
            lastSaveError = String(localized: "Could not save settings")
        }
        SettingsSync.post(.settingsChanged)
    }

    /// Changing the device IP: the same `UserDefaults` key as in the main process,
    /// and a signal to reread it.
    func changeHost(_ newHost: String) {
        let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != host else { return }
        host = trimmed
        UserDefaults.standard.set(trimmed, forKey: SettingsSync.hostKey)
        // `set` hands the value to other processes asynchronously - first we flush
        // it to cfprefsd, and only then signal the main process.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        SettingsSync.post(.settingsChanged)
    }

    /// "Quit" terminates the whole app: a signal to the main process, then to itself.
    func quitApp() {
        SettingsSync.post(.quit)
        NSApp.terminate(nil)
    }

    /// Edits to the schedule from the panel: reread the file. We do not overwrite
    /// an unsaved window draft - `onChange(of:)` in `SettingsView` takes care of that.
    func reloadAutomation() {
        settings = store.load()
    }
}
