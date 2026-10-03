import AppKit
import CatonCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: StatusItemController?
    private var hotKey: HotKey?
    private lazy var settings = SettingsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.openSettings = { [weak self] in self?.settings.show() }
        model.start()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        model.banners.onOpen = { [weak self, weak statusItem] threadID in
            statusItem?.showPanel()
            self?.model.reveal(threadID)
        }
        // Cmd+' by default, as the reference app; Option+Cmd+' when another app
        // holds it. The hot key is the one entry point when the menu bar hides
        // the icon.
        let toggle: @MainActor () -> Void = { [weak statusItem] in statusItem?.togglePanel() }
        hotKey = HotKey(keyCode: 39, modifiers: .command, action: toggle)
            ?? HotKey(keyCode: 39, modifiers: [.command, .option], action: toggle)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.drain()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
