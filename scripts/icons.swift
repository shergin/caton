// Renders the app's image resources from the 1024-pixel originals at the
// repository root: menu bar template images at 18 and 36 pixels, the logo at
// 64 points, and the AppIcon iconset (the logo inset to Apple's icon grid).
// Run through scripts/icons.sh.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let resources = root.appending(path: "Sources/Caton/Resources")
let iconset = URL(fileURLWithPath: CommandLine.arguments[2])

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: root.appending(path: name)) else { fatalError("missing \(name)") }
    return image
}

/// Draws an image into a square canvas of `pixels`, inset by `inset` of the side.
func render(_ image: NSImage, pixels: Int, inset: Double = 0, to url: URL) {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    representation.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSGraphicsContext.current?.imageInterpolation = .high
    let margin = Double(pixels) * inset
    let side = Double(pixels) - margin * 2
    image.draw(in: NSRect(x: margin, y: margin, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! representation.representation(using: .png, properties: [:])!.write(to: url)
}

try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
for state in ["enabled", "active", "disabled"] {
    let icon = load("icon-\(state).png")
    render(icon, pixels: 18, to: resources.appending(path: "menubar-\(state).png"))
    render(icon, pixels: 36, to: resources.appending(path: "menubar-\(state)@2x.png"))
}

let logo = load("logo.png")
render(logo, pixels: 64, to: resources.appending(path: "logo.png"))
render(logo, pixels: 128, to: resources.appending(path: "logo@2x.png"))

// macOS icons keep the artwork inside a margin of about a tenth of the canvas.
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    render(logo, pixels: points, inset: 0.1, to: iconset.appending(path: "icon_\(points)x\(points).png"))
    render(logo, pixels: points * 2, inset: 0.1, to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
