// Context menu of the menu bar icon: `MenuBarExtra` has no right click,
// so we catch it with a local event monitor on the status bar button's window.
// The monitor listens only to `rightMouseDown` - idle costs nothing.
import AppKit

@MainActor
final class StatusItemMenu: NSObject {
    private var monitor: Any?
    private let menu = NSMenu()

    override init() {
        super.init()
        let quit = NSMenuItem(title: String(localized: "Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            // The local monitor is called on the main thread, so the event does not
            // cross an actor boundary - `nonisolated(unsafe)` is only for the compiler.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = event.window,
                      window.className.contains("NSStatusBarWindow"),
                      let view = window.contentView else { return false }
                self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
                return true
            }
            return handled ? nil : event
        }
    }

    @objc private func quit() {
        // The settings process watches the main one and exits by itself.
        NSApp.terminate(nil)
    }
}
