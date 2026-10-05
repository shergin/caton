import AppKit
import SwiftUI

/// The menu bar icon with the Needs me count, the panel it opens, and the
/// dismissal rules around it: Esc, a click elsewhere, opening a thread.
///
/// The panel is dressed as the menu a status item drops: the menu material,
/// no title bar, flush under the menu bar, left-aligned with the icon, the
/// icon held highlighted while it is open, and a menu's quick fade. A real
/// `NSMenu` would give the same chrome but run its own tracking loop that owns
/// the keyboard, which a keyboard-first inbox cannot give up.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: NotificationPanel
    private let window: DetachedWindow
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        panel = NotificationPanel(size: model.preferences.panelSize)
        window = DetachedWindow(model: model)
        super.init()
        window.onClose = { [weak self] in self?.model.preferences.detached = false }
        model.detach = { [weak self] in self?.detach() }
        model.attach = { [weak self] in self?.attach() }
        model.revealPanel = { [weak self] in
            guard let self, !self.model.isPanelVisible else { return }
            self.showPanel()
        }
        let hosting = NSHostingView(rootView: PanelView(model: model, close: { [weak self] in self?.closePanel() }))
        // The window decides its size; the content fits whatever it is given.
        hosting.sizingOptions = []
        panel.host(hosting)
        panel.onResize = { [weak model] size in model?.preferences.panelSize = size }
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
        if model.preferences.detached {
            window.toggle()
        } else if model.isPanelVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        if model.preferences.detached {
            window.show()
        } else {
            showPanel(attempts: 40)
        }
    }

    /// Moves the inbox into its own window.
    func detach() {
        closePanel()
        model.preferences.detached = true
        window.show()
    }

    /// Puts the inbox back under the menu bar icon.
    func attach() {
        model.preferences.detached = false
        window.dismantle()
        model.isPanelVisible = false
        showPanel()
    }

    /// Places the panel under the icon. Right after launch the icon is not in
    /// the menu bar yet and reports a frame at the bottom of the screen; the
    /// panel waits for it rather than opening off screen.
    private func showPanel(attempts: Int) {
        guard let button = statusItem.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main
        else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let menuBarBottom = screen.visibleFrame.maxY
        guard buttonFrame.minY >= menuBarBottom - 1 else {
            guard attempts > 0 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.showPanel(attempts: attempts - 1)
            }
            return
        }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        // Where a status item's menu drops: its left edge at the icon's,
        // pushed back onto the screen when it would run off the right.
        let x = max(visible.minX + 4, min(buttonFrame.minX, visible.maxX - size.width - 4))
        let top = menuBarBottom - NotificationPanel.gap
        // A panel taller than the screen below the menu bar is shortened to fit.
        let height = min(size.height, top - visible.minY - 4)
        panel.setFrame(NSRect(x: x, y: top - height, width: size.width, height: height), display: false)
        panel.present()
        // The button clears its highlight as the click that opened us ends;
        // hold it on the next turn, as a status item does while its menu is open.
        Task { @MainActor [weak self] in
            guard let self, self.model.isPanelVisible else { return }
            self.statusItem.button?.highlight(true)
        }
        model.isPanelVisible = true
        installMonitors()
    }

    func closePanel() {
        panel.dismiss()
        statusItem.button?.highlight(false)
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
        let key = KeyPress(event: event)
        // A focused text field keeps its keys, all but Esc.
        if panel.firstResponder is NSTextView, key.special != .escape { return false }
        return KeyRouter.handle(key, model: model, close: { self.closePanel() })
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
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Caton", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refresh() { model.inbox?.refresh() }
    @objc private func settings() { model.openSettings?() }
    @objc private func checkForUpdates() { model.checkForUpdates() }

    #if DEBUG
    /// Renders the panel's content to a PNG, for checking layout without
    /// screen recording permission.
    func snapshot(to url: URL) {
        let content = model.preferences.detached ? window.contentView : panel.hostedView
        for (view, file) in [(content, url), (statusItem.button, url.deletingPathExtension().appendingPathExtension("menubar.png"))] {
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
        let description = signedIn ? model.countsSummary : "Signed out"
        button.toolTip = "Caton · \(description)"
        button.setAccessibilityLabel("Caton")
        button.setAccessibilityValue(description)
    }
}
