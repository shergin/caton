import AppKit
import SwiftUI

/// The menu bar icon with the Needs me count, the panel it opens, and the
/// dismissal rules around it: Esc, a click elsewhere, opening a thread.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: NotificationPanel
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        panel = NotificationPanel()
        super.init()
        panel.contentView = NSHostingView(rootView: PanelView(model: model, close: { [weak self] in self?.closePanel() }))
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        observeCount()
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if panel.isVisible { closePanel() } else { showPanel() }
    }

    func showPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(buttonFrame.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: buttonFrame.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        model.isPanelVisible = true
        installMonitors()
    }

    func closePanel() {
        panel.orderOut(nil)
        model.isPanelVisible = false
        removeMonitors()
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let key = event
            let handled = MainActor.assumeIsolated { self?.route(key) ?? false }
            return handled ? nil : event
        }
    }

    private func route(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow else { return false }
        // A focused text field keeps its keys.
        if panel.firstResponder is NSTextView, event.keyCode != 53 { return false }
        return KeyRouter.handle(event, model: model, close: { self.closePanel() })
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Caton", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refresh() { model.refresh() }
    @objc private func settings() { model.openSettings?() }

    #if DEBUG
    /// Renders the panel's content to a PNG, for checking layout without
    /// screen recording permission.
    func snapshot(to url: URL) {
        for (view, file) in [(panel.contentView, url), (statusItem.button, url.deletingPathExtension().appendingPathExtension("menubar.png"))] {
            guard let view, let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: representation)
            try? representation.representation(using: .png, properties: [:])?.write(to: file)
        }
    }
    #endif

    /// Redraws the icon whenever the count or the account changes.
    private func observeCount() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCount() }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let count = model.needsMeCount
        let signedIn = if case .signedIn = model.account { true } else { false }
        let state: Assets.MenuBar = !signedIn || model.errorMessage != nil ? .disabled : count > 0 ? .active : .enabled
        button.image = Assets.menuBar(state)
        button.title = signedIn && count > 0 && model.preferences.showsCount ? " \(count)" : ""
        let description = signedIn ? (count == 1 ? "1 thing needs you" : "\(count) things need you") : "Signed out"
        button.toolTip = "Caton · \(description)"
        button.setAccessibilityValue(description)
    }
}

/// A floating, non-activating panel: it takes the keyboard without bringing
/// the app forward, and sits above full-screen apps on the current Space.
final class NotificationPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
