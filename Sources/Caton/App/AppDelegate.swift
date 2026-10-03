import AppKit
import CatonCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: StatusItemController?
    private var hotKey: HotKey?
    private lazy var settings = SettingsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundled app takes its icon from Info.plist; `swift run` has none.
        if Bundle.main.bundleIdentifier == nil, let icon = Assets.appIcon {
            NSApp.applicationIconImage = icon
        }
        model.openSettings = { [weak self] in self?.settings.show() }
        model.start()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        model.banners.onOpen = { [weak self, weak statusItem] threadID in
            statusItem?.showPanel()
            self?.model.reveal(threadID)
        }
        registerHotKey()
        if case .signedOut = model.account {
            statusItem.showPanel()
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CATON_OPEN_PANEL"] == "1" {
            statusItem.showPanel()
        }
        if let section = ProcessInfo.processInfo.environment["CATON_SECTION"].flatMap(Int.init).flatMap(Split.init(rawValue:)) {
            model.show(.split(section))
        }
        let environment = ProcessInfo.processInfo.environment
        if environment["CATON_SHOW_SETTINGS"] == "1" { settings.show() }
        if let path = environment["CATON_SNAPSHOT"] {
            Task {
                try? await Task.sleep(for: .seconds(4))
                switch environment["CATON_OVERLAY"] {
                case "peek": model.peek()
                case "help": model.overlay = .help
                case "commands": model.overlay = .commands
                case "snooze": model.overlay = .snooze
                default: break
                }
                try? await Task.sleep(for: .seconds(2))
                statusItem.snapshot(to: URL(fileURLWithPath: path))
                settings.snapshot(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-settings.png")))
            }
        }
        #endif
    }

    /// Registers the user's shortcut, and again whenever it changes. The hot
    /// key is the one entry point when the menu bar hides the icon.
    private func registerHotKey() {
        let preferences = model.preferences
        let combination = withObservationTracking { preferences.hotKey } onChange: {
            Task { @MainActor [weak self] in self?.registerHotKey() }
        }
        hotKey = nil
        let toggle: @MainActor () -> Void = { [weak self] in self?.statusItem?.togglePanel() }
        if let registered = HotKey(keyCode: combination.keyCode, modifiers: combination.modifierFlags, action: toggle) {
            hotKey = registered
            preferences.hotKeyStatus = nil
        } else if combination == .standard, let registered = HotKey(keyCode: HotKeyCombination.fallback.keyCode, modifiers: HotKeyCombination.fallback.modifierFlags, action: toggle) {
            // Another app holds Cmd+'; Option+Cmd+' stands in until the user picks one.
            hotKey = registered
            preferences.hotKeyStatus = "\(combination.display) is taken by another app; using \(HotKeyCombination.fallback.display)."
        } else {
            preferences.hotKeyStatus = "\(combination.display) is taken by another app. Pick another."
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.drain()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
