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
    /// Accounts that have seen the first-sync summary.
    var welcomedAccounts: Set<String> { didSet { defaults.set(Array(welcomedAccounts), forKey: "welcomedAccounts") } }
    private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        syncRuleClears = defaults.bool(forKey: "syncRuleClears")
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        quietHours = defaults.data(forKey: "quietHours").flatMap { try? JSONDecoder().decode(QuietHours.self, from: $0) } ?? QuietHours()
        showsCount = defaults.object(forKey: "showsCount") as? Bool ?? true
        welcomedAccounts = Set(defaults.stringArray(forKey: "welcomedAccounts") ?? [])
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
