import AppKit
import SwiftUI

/// The inbox in an ordinary window, for keeping it open beside other work:
/// it resizes and moves freely, stays put when the user clicks elsewhere,
/// and remembers its frame. Closing it puts the inbox back under the menu
/// bar icon.
@MainActor
final class DetachedWindow: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var keyMonitor: Any?
    /// Called when the user closes the window: the panel takes over again.
    var onClose: (() -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var contentView: NSView? { window?.contentView }
    var isKey: Bool { window?.isKeyWindow ?? false }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        model.isPanelVisible = true
    }

    /// The menu bar icon and the shortcut bring the window forward, or hide
    /// it when it is already in front.
    func toggle() {
        if isKey { hide() } else { show() }
    }

    func hide() {
        window?.orderOut(nil)
        model.isPanelVisible = false
        model.isWindowInBackground = false
    }

    /// Closes for good, without asking the panel to take over.
    func dismantle() {
        let onClose = onClose
        self.onClose = nil
        window?.close()
        self.onClose = onClose
    }

    private func makeWindow() -> NSWindow {
        let size = model.preferences.panelSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Caton"
        // The inbox's own header names it; the title bar only holds the buttons.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NotificationPanel.minimumSize
        window.contentView = NSHostingView(rootView: PanelView(model: model, close: {}))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("CatonInbox")
        return window
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        model.isWindowInBackground = false
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let key = event
            let handled = MainActor.assumeIsolated { self?.route(key) ?? false }
            return handled ? nil : event
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Out of sight, banners are welcome again.
        model.isWindowInBackground = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.isPanelVisible = false
        model.isWindowInBackground = false
        onClose?()
    }

    private func route(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow else { return false }
        // An agent app has no menu bar to give these their usual meaning.
        if event.modifierFlags.intersection([.command, .control, .option]) == .command {
            switch event.charactersIgnoringModifiers {
            case "w": window.performClose(nil); return true
            case "m": window.miniaturize(nil); return true
            default: break
            }
        }
        if window.firstResponder is NSTextView, event.keyCode != 53 { return false }
        // A window does not close on Esc or after opening a thread.
        return KeyRouter.handle(event, model: model, close: {})
    }
}
