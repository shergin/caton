import AppKit

/// The alert a user-initiated update check shows. The model asks for the
/// check; the shell presents it.
@MainActor
enum UpdatePrompt {
    static func show(_ updates: Updates, openURL: @MainActor (URL) -> Void) async {
        await updates.check(userInitiated: true)
        let alert = NSAlert()
        alert.messageText = updates.status ?? "Caton \(updates.currentVersion)"
        if let release = updates.available {
            alert.informativeText = "You have \(updates.currentVersion). Update with:\n\(Updates.upgradeCommand)"
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn: updates.copyUpgradeCommand()
            case .alertSecondButtonReturn: openURL(release.url)
            default: break
            }
        } else {
            NSApp.activate()
            alert.runModal()
        }
    }
}
