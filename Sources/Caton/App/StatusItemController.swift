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
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        panel = NotificationPanel()
        super.init()
        panel.host(NSHostingView(rootView: PanelView(model: model, close: { [weak self] in self?.closePanel() })))
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
        if model.isPanelVisible { closePanel() } else { showPanel() }
    }

    func showPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Where a status item's menu drops: its left edge at the icon's,
        // pushed back onto the screen when it would run off the right.
        let x = min(max(buttonFrame.minX, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: buttonFrame.minY - size.height - NotificationPanel.gap))
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

/// A floating, non-activating panel in a menu's clothes: borderless, the
/// menu material behind rounded corners, the window server's shadow. It takes
/// the keyboard without bringing the app forward, and sits above full-screen
/// apps on the current Space.
final class NotificationPanel: NSPanel {
    static let size = NSSize(width: 420, height: 560)
    /// The corner radius of macOS 26 menus, measured by eye.
    static let cornerRadius: CGFloat = 12
    /// The space between the menu bar and the panel, as menus leave.
    static let gap: CGFloat = 3

    private let background = NSVisualEffectView()
    private var fade: Task<Void, Never>?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]

        // The material menus are drawn with, kept active although the app is not.
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        contentView = background
    }

    /// Puts the content on the material, filling it.
    func host(_ view: NSView) {
        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
    }

    /// Shows the panel with a menu's quick fade.
    func present() {
        fade?.cancel()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 1
        }
    }

    /// Hides the panel with a menu's quick fade.
    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        }
        fade = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.orderOut(nil)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A stretchable rounded rectangle: the material shows only inside it,
    /// and the shadow follows it.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
