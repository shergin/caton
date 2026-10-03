import AppKit

/// The app's images, rendered by scripts/icons.sh from the originals at the
/// repository root.
@MainActor
enum Assets {
    /// SwiftPM's resource bundle: inside Contents/Resources in the bundled
    /// app, beside the executable under `swift run`.
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appending(path: "Caton_Caton.bundle"), let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    /// The menu bar's states, as template images the system tints.
    enum MenuBar: String {
        /// Signed out, or the account cannot be reached.
        case disabled
        /// Signed in, and nothing needs the user.
        case enabled
        /// Something needs the user.
        case active
    }

    static func menuBar(_ state: MenuBar) -> NSImage? {
        guard let image = bundle.image(forResource: "menubar-\(state.rawValue)") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    static let logo: NSImage? = bundle.image(forResource: "logo")

    static let appIcon: NSImage? = bundle.image(forResource: "AppIcon")
}
