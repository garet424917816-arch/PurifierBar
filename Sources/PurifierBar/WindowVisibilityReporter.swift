// Workaround for the unreliable `onDisappear` in `MenuBarExtra` content: we watch the window
// in which this invisible view is embedded, and report its appearance and disappearance.
import AppKit
import SwiftUI

struct WindowVisibilityReporter: NSViewRepresentable {
    /// Called on the main actor: true - the window appeared, false - it disappeared.
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReporterView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReporterView)?.onChange = onChange
    }
}

/// Listens to events of its window: appearance (key or visible area) and closing.
@MainActor
final class ReporterView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { removeObservers() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        tokens.append(observe(center, NSWindow.didBecomeKeyNotification, of: window) { true })
        // Losing key or the visible area - the panel window has disappeared from the screen.
        tokens.append(observe(center, NSWindow.didResignKeyNotification, of: window) { false })
        tokens.append(observe(center, NSWindow.didChangeOcclusionStateNotification, of: window) {
            window.isVisible && window.occlusionState.contains(.visible)
        })
        tokens.append(observe(center, NSWindow.willCloseNotification, of: window) { false })
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        of window: NSWindow,
        _ value: @escaping @MainActor () -> Bool
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onChange?(value()) }
        }
    }

    private func removeObservers() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}
