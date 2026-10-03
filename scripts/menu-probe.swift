// Opens a real NSMenu for a moment and prints how AppKit builds its window:
// window class and flags, the view tree, materials, glass and layers. This is
// how Caton's panel matches the system's menus; run it again on a new macOS:
//
//     swiftc -o /tmp/menu-probe scripts/menu-probe.swift && /tmp/menu-probe
import AppKit
import QuartzCore

func describeLayer(_ layer: CALayer, depth: Int) {
    let pad = String(repeating: "  ", count: depth)
    var parts = ["\(pad)layer \(type(of: layer))", "frame \(layer.frame.integral)"]
    if layer.cornerRadius > 0 { parts.append("cornerRadius \(layer.cornerRadius) curve \(layer.cornerCurve.rawValue)") }
    if layer.masksToBounds { parts.append("masks") }
    if let color = layer.backgroundColor { parts.append("bg \(color)") }
    if let filters = layer.filters, !filters.isEmpty { parts.append("filters \(filters)") }
    if let compositing = layer.compositingFilter { parts.append("compositing \(compositing)") }
    if layer.opacity < 1 { parts.append("opacity \(layer.opacity)") }
    print(parts.joined(separator: " · "))
    for sub in layer.sublayers ?? [] where depth < 7 { describeLayer(sub, depth: depth + 1) }
}

func describeView(_ view: NSView, depth: Int) {
    let pad = String(repeating: "  ", count: depth)
    var parts = ["\(pad)\(type(of: view))", "frame \(view.frame.integral)"]
    if let effect = view as? NSVisualEffectView {
        parts.append("material \(effect.material.rawValue) blending \(effect.blendingMode.rawValue) state \(effect.state.rawValue) emphasized \(effect.isEmphasized) mask \(effect.maskImage != nil)")
    }
    if let glass = view as? NSGlassEffectView {
        parts.append("GLASS cornerRadius \(glass.cornerRadius) style \(glass.style.rawValue) tint \(String(describing: glass.tintColor))")
    }
    if let appearance = view.appearance { parts.append("appearance \(appearance.name.rawValue)") }
    print(parts.joined(separator: " · "))
    if depth < 4, let layer = view.layer { describeLayer(layer, depth: depth + 1) }
    for sub in view.subviews where depth < 6 { describeView(sub, depth: depth + 1) }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let menu = NSMenu()
for title in ["Refresh", "Settings…", "Quit"] { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }

DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
        print("effective appearance:", NSApp.effectiveAppearance.name.rawValue)
        for window in NSApp.windows where window.isVisible {
            print("WINDOW \(type(of: window)) frame \(window.frame.integral) level \(window.level.rawValue) opaque \(window.isOpaque) bg \(String(describing: window.backgroundColor)) shadow \(window.hasShadow) style \(window.styleMask.rawValue) alpha \(window.alphaValue)")
            if let frameView = window.contentView?.superview { describeView(frameView, depth: 0) } else if let content = window.contentView { describeView(content, depth: 0) }
        }
        menu.cancelTracking()
    }
    RunLoop.main.add(timer, forMode: .common)
    menu.popUp(positioning: nil, at: NSPoint(x: 40, y: (NSScreen.main?.frame.maxY ?? 900) - 60), in: nil)
    exit(0)
}
application.run()
