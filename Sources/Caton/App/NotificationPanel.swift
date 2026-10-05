import AppKit

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
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = animates ? 0 : 1
        makeKeyAndOrderFront(nil)
        invalidateShadow()
        guard animates else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 1
        }
    }

    /// Hides the panel with a menu's quick fade.
    func dismiss() {
        guard isVisible else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            fade?.cancel()
            orderOut(nil)
            return
        }
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
    static let corner: CGFloat = 14

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
