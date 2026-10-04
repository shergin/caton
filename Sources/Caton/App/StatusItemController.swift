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
        panel = NotificationPanel(size: model.preferences.panelSize)
        super.init()
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
        if model.isPanelVisible { closePanel() } else { showPanel() }
    }

    func showPanel() {
        showPanel(attempts: 40)
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
        for (view, file) in [(panel.hostedView, url), (statusItem.button, url.deletingPathExtension().appendingPathExtension("menubar.png"))] {
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

/// A floating, non-activating panel drawn the way macOS 26 draws a menu.
/// Measured with scripts/menu-probe.swift: an `NSPopupMenuWindow` is a
/// borderless, non-opaque window with a shadow whose background is an
/// `NSGlassView`, AppKit's own `NSGlassEffectView`, at a corner radius of 12
/// in the regular style. This panel is the same, so it looks like a menu, but
/// it is an ordinary window: it takes the keyboard without bringing the app
/// forward, and it resizes from its sides and bottom while its top stays
/// under the menu bar.
///
/// The content sits above the glass rather than inside it: the glass treats
/// what it holds as vibrant, which would grey out the inbox's colors.
final class NotificationPanel: NSPanel {
    static let defaultSize = NSSize(width: 420, height: 560)
    static let minimumSize = NSSize(width: 360, height: 320)
    static let cornerRadius: CGFloat = 12
    /// The space between the menu bar and the panel, as menus leave.
    static let gap: CGFloat = 3

    private let glass = NSGlassEffectView()
    private let container: NSView
    /// The content, above the glass.
    private(set) var hostedView: NSView?
    private var fade: Task<Void, Never>?
    /// Called with the new size when the user finishes resizing.
    var onResize: ((NSSize) -> Void)?

    init(size: NSSize) {
        container = NSView(frame: NSRect(origin: .zero, size: size))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = Self.minimumSize
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]

        // Menus have the window server round the window, its edge and its
        // shadow (AppKit's private `_setCornerRadius:`, 12 for a menu window);
        // without it the server outlines the window's rectangle around the glass.
        if responds(to: Selector(("_setCornerRadius:"))) {
            setValue(Self.cornerRadius, forKey: "cornerRadius")
        }

        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        // The handles sit above the glass, along the edges a menu could grow from.
        for edge in ResizeHandle.Edge.allCases {
            container.addSubview(ResizeHandle(edge: edge, in: container.bounds))
        }
        contentView = container
    }

    /// Puts the content above the glass, filling it, under the resize handles.
    func host(_ view: NSView) {
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: .above, relativeTo: glass)
        hostedView = view
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

    func didFinishResizing() {
        invalidateShadow()
        onResize?(frame.size)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// As a menu window: the rounded corners also shape the shadow.
    @objc(_cornerMaskShouldDefineShadow) private func cornerMaskShouldDefineShadow() -> Bool { true }

    /// As a menu window: the window server's menu shadow.
    @objc(shadowOptions) private func menuShadowOptions() -> UInt { 2 }
}

/// A strip along one edge of the panel that resizes it. A borderless window
/// has no resize edges of its own; these stand in, with the system's resize
/// cursors. The top edge is not one of them: the panel hangs from the menu bar.
final class ResizeHandle: NSView {
    enum Edge: CaseIterable {
        case left, right, bottom, bottomLeft, bottomRight
    }

    static let thickness: CGFloat = 5
    static let corner: CGFloat = 16

    private let edge: Edge
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero

    init(edge: Edge, in bounds: NSRect) {
        self.edge = edge
        let thickness = Self.thickness
        let corner = Self.corner
        let frame: NSRect
        let mask: NSView.AutoresizingMask
        switch edge {
        case .left:
            frame = NSRect(x: 0, y: corner, width: thickness, height: bounds.height - corner)
            mask = [.height, .maxXMargin]
        case .right:
            frame = NSRect(x: bounds.width - thickness, y: corner, width: thickness, height: bounds.height - corner)
            mask = [.height, .minXMargin]
        case .bottom:
            frame = NSRect(x: corner, y: 0, width: bounds.width - corner * 2, height: thickness)
            mask = [.width, .maxYMargin]
        case .bottomLeft:
            frame = NSRect(x: 0, y: 0, width: corner, height: corner)
            mask = [.maxXMargin, .maxYMargin]
        case .bottomRight:
            frame = NSRect(x: bounds.width - corner, y: 0, width: corner, height: corner)
            mask = [.minXMargin, .maxYMargin]
        }
        super.init(frame: frame)
        autoresizingMask = mask
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The bottom-right corner shows a grip: three short diagonal strokes,
    /// inset to stay inside the panel's rounded corner.
    override func draw(_ dirtyRect: NSRect) {
        guard edge == .bottomRight else { return }
        let path = NSBezierPath()
        let inset: CGFloat = 4
        for length in [4.0, 7.5, 11.0] {
            path.move(to: NSPoint(x: bounds.maxX - inset - length, y: inset))
            path.line(to: NSPoint(x: bounds.maxX - inset, y: inset + length))
        }
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch edge {
        case .left: .frameResize(position: .left, directions: .all)
        case .right: .frameResize(position: .right, directions: .all)
        case .bottom: .frameResize(position: .bottom, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        let minimum = window.minSize
        let visible = window.screen?.visibleFrame ?? .infinite
        var frame = startFrame
        if edge == .left || edge == .bottomLeft {
            let width = max(minimum.width, startFrame.width - dx)
            frame.origin.x = max(visible.minX, startFrame.maxX - width)
            frame.size.width = startFrame.maxX - frame.origin.x
        }
        if edge == .right || edge == .bottomRight {
            frame.size.width = min(max(minimum.width, startFrame.width + dx), visible.maxX - startFrame.minX)
        }
        if edge == .bottom || edge == .bottomLeft || edge == .bottomRight {
            // The top stays where it is; the bottom follows the mouse.
            let height = min(max(minimum.height, startFrame.height - dy), startFrame.maxY - visible.minY)
            frame.origin.y = startFrame.maxY - height
            frame.size.height = height
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        (window as? NotificationPanel)?.didFinishResizing()
    }
}
