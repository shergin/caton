import AppKit
import CatonCore
import Foundation
import Observation
import ServiceManagement

/// The user's app-level choices, kept in user defaults. Classification
/// settings live in `LocalState` with the rest of the inbox's state.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// Rule clears reach GitHub only after the user says so.
    var syncRuleClears: Bool { didSet { defaults.set(syncRuleClears, forKey: "syncRuleClears") } }
    var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    var quietHours: QuietHours { didSet { defaults.set(try? JSONEncoder().encode(quietHours), forKey: "quietHours") } }
    /// The Needs me count beside the icon; off shows the filled icon alone.
    var showsCount: Bool { didSet { defaults.set(showsCount, forKey: "showsCount") } }
    /// The panel's size, as the user last left it.
    var panelSize: NSSize {
        didSet {
            defaults.set(panelSize.width, forKey: "panelWidth")
            defaults.set(panelSize.height, forKey: "panelHeight")
        }
    }
    /// The global shortcut that toggles the panel.
    var hotKey: HotKeyCombination { didSet { defaults.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey") } }
    /// What the shortcut registered as, or why it could not be.
    var hotKeyStatus: String?
    /// Accounts that have seen the first-sync summary.
    var welcomedAccounts: Set<String> { didSet { defaults.set(Array(welcomedAccounts), forKey: "welcomedAccounts") } }
    /// Whether the three-key tip has been shown.
    var tipsShown: Bool { didSet { defaults.set(tipsShown, forKey: "tipsShown") } }
    private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        syncRuleClears = defaults.bool(forKey: "syncRuleClears")
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        quietHours = defaults.data(forKey: "quietHours").flatMap { try? JSONDecoder().decode(QuietHours.self, from: $0) } ?? QuietHours()
        showsCount = defaults.object(forKey: "showsCount") as? Bool ?? true
        let width = defaults.double(forKey: "panelWidth")
        let height = defaults.double(forKey: "panelHeight")
        panelSize = width > 0 && height > 0 ? NSSize(width: width, height: height) : NotificationPanel.defaultSize
        hotKey = defaults.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeyCombination.self, from: $0) } ?? .standard
        welcomedAccounts = Set(defaults.stringArray(forKey: "welcomedAccounts") ?? [])
        tipsShown = defaults.bool(forKey: "tipsShown")
    }

    /// Launch at login needs the bundled app; `swift run` has no bundle to register.
    var canLaunchAtLogin: Bool { Bundle.main.bundleIdentifier != nil }

    var launchAtLogin: Bool {
        get { canLaunchAtLogin && SMAppService.mainApp.status == .enabled }
        set {
            guard canLaunchAtLogin else { return }
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = "macOS refused: allow Caton in System Settings › General › Login Items."
            }
        }
    }
}

/// A key with modifiers, as Carbon registers it and as the user reads it.
struct HotKeyCombination: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt
    var display: String

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    static let standard = HotKeyCombination(keyCode: 39, modifiers: NSEvent.ModifierFlags.command.rawValue, display: "⌘'")
    /// Used when another app holds the standard shortcut and the user has not chosen one.
    static let fallback = HotKeyCombination(keyCode: 39, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, display: "⌥⌘'")

    /// The combination a key press makes, if it has a modifier that keeps it
    /// from colliding with typing: Command, Option or Control.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = flags.rawValue
        display = Self.symbols(flags) + Self.keyName(event)
    }

    init(keyCode: UInt32, modifiers: UInt, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111:
            let keys: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            return keys[event.keyCode] ?? "?"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
