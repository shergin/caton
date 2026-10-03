import AppKit
import CatonCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: StatusItemController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
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
        if let path = ProcessInfo.processInfo.environment["CATON_SNAPSHOT"] {
            Task {
                try? await Task.sleep(for: .seconds(5))
                statusItem.snapshot(to: URL(fileURLWithPath: path))
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
