// Menu bar app: MenuBarExtra with a panel in `.window` style.
// The settings window lives in a separate process (`SettingsProcess`), which
// is started with the same binary and the `--settings` argument (see `Entry`).
import SwiftUI

struct PurifierBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The start of the chain happens right after launch, before the panel is opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let statusMenu = StatusItemMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        statusMenu.install()
    }
}
