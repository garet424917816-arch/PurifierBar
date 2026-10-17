// Settings window process. The same binary, started with `--settings`:
// its own `NSApplication`, one window, exits on close. No Keychain, no
// sockets, no `AppModel` - only the settings file and `UserDefaults`.
import AppKit
import Foundation
import SwiftUI

@MainActor
enum SettingsProcess {
    /// Strong reference to the delegate: `NSApplication.delegate` does not hold it.
    private static var delegate: SettingsAppDelegate?

    /// Entry point of settings mode. Called from the main thread.
    static func run() {
        // The parent is already gone (the process was inherited by launchd) - nobody to show to.
        let parent = getppid()
        guard parent != 1 else { return }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = SettingsAppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // Notifications are registered before `run()`: otherwise a `show` sent in the moment between
        // process launch and the start of the event loop would be lost.
        delegate.registerNotifications(parent: parent)
        app.run()
    }
}

/// Delegate of the settings process: menu, window, notifications and parent watching.
@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var session: SettingsSession?
    /// Source watching the parent; lives as long as the process does.
    private var parentWatch: DispatchSourceProcess?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        buildWindow()
    }

    /// Subscriptions to notifications from the main process.
    func registerNotifications(parent: pid_t) {
        guard observers.isEmpty else { return }
        observers.append(SettingsSync.observe(.show) { [weak self] in
            self?.bringToFront()
        })
        observers.append(SettingsSync.observe(.automationChanged) { [weak self] in
            self?.session?.reloadAutomation()
        })
        observers.append(SettingsSync.observe(.quit) {
            NSApp.terminate(nil)
        })
        watchParent(parent)
    }

    // MARK: - Menu

    /// Minimal main menu so that Cmd+Q, Cmd+W and the editing keys work.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu: the only command is close the window (the process exits after it).
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        _ = appMenu.addItem(
            withTitle: String(localized: "Close Settings"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // "Edit" menu - standard selectors via the responder chain.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        let editItems: [(title: String, action: Selector, key: String, mask: NSEvent.ModifierFlags)] = [
            (String(localized: "Undo"), Selector(("undo:")), "z", .command),
            (String(localized: "Redo", table: "EditMenu"), Selector(("redo:")), "z", [.command, .shift]),
        ]
        for entry in editItems {
            let item = editMenu.addItem(withTitle: entry.title, action: entry.action, keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.mask
        }
        editMenu.addItem(.separator())
        _ = editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        _ = editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        _ = editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        _ = editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // "Window" menu: Cmd+W closes the window.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        _ = windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Window

    /// The window is created the same way as in the T9-T10 controller: the same size,
    /// style and first responder (see the comment about the text system below).
    private func buildWindow() {
        let session = SettingsSession()
        self.session = session

        let host = NSHostingController(rootView: SettingsView(session: session))
        // From SwiftUI we take only the minimum (480 x 420): `.preferredContentSize`
        // and `.maxSize` pin the window to the content size and prevent resizing.
        host.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: host)
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Only the delegate owns the window - AppKit must not release it itself.
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Start size 480 x 700; width fixed, height resizable.
        window.setContentSize(NSSize(width: 480, height: 700))
        window.contentMaxSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        window.center()
        self.window = window

        // The first focus in a text field makes AppKit load the text
        // system (field editor, key bindings, ICU) - its caches live until the end of
        // the process and exceed the memory budget (T10: measured 41 -> 38 MB when
        // the field does not get focus). `NSWindow` on the first `makeKeyAndOrderFront`
        // without `initialFirstResponder` itself takes the first view of the key view loop that
        // accepts focus - and that is the IP field. So before showing, we set
        // `initialFirstResponder` - the `NSHostingView` itself, not a text control;
        // and after showing we pin the choice synchronously, so AppKit does not manage to
        // pick the field. The field stays editable - focus arrives by clicking.
        window.initialFirstResponder = host.view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // `NSHostingView` may not accept first responder; then we leave
        // first responder empty (the window itself), so the field does not become it.
        if !window.makeFirstResponder(host.view) {
            window.makeFirstResponder(nil)
        }
    }

    /// Bring the window to the foreground (`show` notification).
    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Lifecycle

    /// Closing the window - the end of the settings process.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        NSApp.terminate(nil)
    }

    /// The parent has exited - we exit too, so as not to be left an orphan.
    /// We watch exactly the PID saved at start: if the parent died before this
    /// point, a repeated `getppid()` would already return launchd (1).
    private func watchParent(_ parent: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: parent,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        parentWatch = source
        // The parent could have exited before the source was registered - then there will be no event.
        if getppid() != parent {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
