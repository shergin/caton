import AppKit
import CatonCore

/// One thing the user can do, with the keys that do it. The command menu
/// lists these with their shortcuts, so running a command teaches its key.
@MainActor
struct Command: Identifiable {
    let id: String
    let title: String
    let keys: String
    let closesPanel: Bool
    let run: (AppModel) -> Void

    init(_ id: String, _ title: String, keys: String, closesPanel: Bool = false, run: @escaping (AppModel) -> Void) {
        self.id = id
        self.title = title
        self.keys = keys
        self.closesPanel = closesPanel
        self.run = run
    }

    static let all: [Command] = [
        Command("open", "Open in browser", keys: "⏎  o", closesPanel: true) { $0.open() },
        Command("done", "Done", keys: "e  d") { $0.done() },
        Command("snooze", "Snooze…", keys: "h") { $0.beginSnooze() },
        Command("unsubscribe", "Unsubscribe (mentions still notify)", keys: "u") { $0.unsubscribe() },
        Command("ignore", "Ignore thread (never notify)", keys: "") { $0.ignore() },
        Command("later", "Save for later", keys: "b") { $0.toggleLater() },
        Command("read", "Mark read", keys: "m") { $0.markRead() },
        Command("select", "Select for bulk", keys: "x") { $0.toggleChecked() },
        Command("bundle", "Open or close a Feed bundle", keys: "→  ←") { model in
            if let bundle = model.selectedBundle { model.toggleBundle(bundle.id) } else { model.collapseSelection() }
        },
        Command("undo", "Undo", keys: "z  ⌘Z") { $0.undo() },
        Command("copy", "Copy link", keys: "y") { $0.copyLink() },
        Command("peek", "Peek at the latest", keys: "p") { $0.peek() },
        Command("why", "Why is this here?", keys: "") { $0.explain() },
        Command("mute", "Mute this repository", keys: "") { $0.muteRepository() },
        Command("zero", "Get me to zero…", keys: "") { $0.overlay = .zero },
        Command("next-split", "Next split", keys: "⇥") { $0.cycleSplit(by: 1) },
        Command("needs-me", "Go to Needs me", keys: "1") { $0.show(.split(.needsMe)) },
        Command("team", "Go to Team", keys: "2") { $0.show(.split(.team)) },
        Command("following", "Go to Following", keys: "3") { $0.show(.split(.following)) },
        Command("feed", "Go to Feed", keys: "4") { $0.show(.split(.feed)) },
        Command("my-pull-requests", "Go to My pull requests", keys: "g p") { $0.show(.myPullRequests) },
        Command("snoozed", "Go to Snoozed", keys: "g s") { $0.show(.snoozed) },
        Command("later-list", "Go to Later", keys: "g l") { $0.show(.later) },
        Command("cleared", "Go to Cleared", keys: "g c") { $0.show(.cleared) },
        Command("search", "Search", keys: "/") { $0.isSearching = true },
        Command("save-search", "Save search as a split…", keys: "") { $0.beginSavingSearch() },
        Command("delete-search", "Delete this saved split", keys: "") { model in
            if case .saved(let id) = model.section { model.deleteSavedSearch(id) }
        },
        Command("unread", "Unread only", keys: "a") { $0.unreadOnly.toggle() },
        Command("group", "Group by repository", keys: "s") { $0.groupByRepository.toggle() },
        Command("refresh", "Refresh", keys: "r") { $0.refresh() },
        Command("keys", "Keyboard shortcuts", keys: "?") { $0.overlay = .help },
        Command("practice", "Practice inbox (made-up threads) / leave it", keys: "") { model in
            model.isPractice ? model.exitPractice() : model.enterPractice()
        },
        Command("detach", "Open in a window / back to the menu bar", keys: "") { model in
            model.preferences.detached ? model.attach?() : model.detach?()
        },
        Command("switch-account", "Switch to the next account", keys: "") { $0.switchToNextAccount() },
        Command("add-account", "Add an account…", keys: "") { $0.addAccount() },
        Command("settings", "Settings…", keys: "⌘,") { $0.openSettings?() },
        Command("updates", "Check for updates…", keys: "", closesPanel: true) { $0.checkForUpdates() },
    ]
}

/// Routes the panel's keys. Navigation keys repeat; verbs fire once per press.
@MainActor
enum KeyRouter {
    static let page = 8

    static func handle(_ event: NSEvent, model: AppModel, close: () -> Void) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let characters = event.characters ?? ""
        let isRepeat = event.isARepeat

        switch model.overlay {
        case .snooze:
            if event.keyCode == 53 { model.overlay = .none; return true }
            if case .pullRequest(let id) = model.snoozeTarget {
                if characters == "x" {
                    model.overlay = .none
                    model.clearReminder(id)
                    return true
                }
            } else if characters == "n" {
                model.snoozeOnlyIfQuiet.toggle()
                return true
            }
            if let option = SnoozeOption.all.first(where: { $0.key == characters }) { model.chooseSnooze(option.date()) }
            return true
        case .help, .why:
            model.overlay = .none
            return true
        case .peek:
            model.overlay = .none
            switch characters {
            case "o", "\r": if model.open() { close() }
            case "e", "d": model.done()
            default: break
            }
            if event.keyCode == 36 || event.keyCode == 76, model.open() { close() }
            return true
        case .welcome:
            if event.keyCode == 53 || event.keyCode == 36 { model.finishWelcome(syncRuleClears: false) }
            return true
        case .commands, .saveSearch:
            if event.keyCode == 53 { model.overlay = .none; return true }
            return false
        case .zero:
            if event.keyCode == 53 { model.overlay = .none; return true }
            if !isRepeat, let option = model.zeroOptions.first(where: { $0.key == characters }) { model.getMeToZero(option) }
            return true
        case .tips:
            // Any key ends the tip; the keys it teaches also do their job.
            model.dismissTips()
            if event.keyCode == 53 { return true }
        case .none:
            break
        }

        if flags == .command {
            switch event.keyCode {
            case 125: model.selectLast(); return true
            case 126: model.selectFirst(); return true
            default: break
            }
            switch characters.lowercased() {
            case "z": model.undo(); return true
            case "k": model.overlay = .commands; return true
            case ",": model.openSettings?(); return true
            default: return false
            }
        }
        if flags == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": model.moveSelection(by: page); return true
            case "b": model.moveSelection(by: -page); return true
            case "d": model.moveSelection(by: page / 2); return true
            case "u": model.moveSelection(by: -page / 2); return true
            default: return false
            }
        }
        guard flags.isEmpty else { return false }

        switch event.keyCode {
        case 125: model.moveSelection(by: 1); return true
        case 126: model.moveSelection(by: -1); return true
        case 124: model.expandSelection(); return true
        case 123: model.collapseSelection(); return true
        case 121: model.moveSelection(by: page); return true
        case 116: model.moveSelection(by: -page); return true
        case 115: model.selectFirst(); return true
        case 119: model.selectLast(); return true
        case 48:
            model.cycleSplit(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 53:
            if model.isSearching || !model.searchQuery.isEmpty {
                model.searchQuery = ""
                model.isSearching = false
            } else if !model.checked.isEmpty {
                model.clearChecked()
            } else {
                close()
            }
            return true
        case 36, 76:
            if !isRepeat, model.open() { close() }
            return true
        default:
            break
        }

        if model.pendingG {
            model.pendingG = false
            switch characters {
            case "g": model.selectFirst()
            case "s": model.show(.snoozed)
            case "l": model.show(.later)
            case "c": model.show(.cleared)
            case "p": model.show(.myPullRequests)
            default: break
            }
            return true
        }

        // Navigation repeats while held.
        switch characters {
        case "j": model.moveSelection(by: 1); return true
        case "k": model.moveSelection(by: -1); return true
        case " ": model.moveSelection(by: page); return true
        default: break
        }
        // Everything else fires once per press, so holding `d` never empties the inbox.
        if isRepeat { return true }
        switch characters {
        case "g": model.pendingG = true
        case "G": model.selectLast()
        case "o": if model.open() { close() }
        case "e", "d": model.done()
        case "h": model.beginSnooze()
        case "u": model.unsubscribe()
        case "b": model.toggleLater()
        case "m": model.markRead()
        case "x": model.toggleChecked()
        case "z": model.undo()
        case "y": model.copyLink()
        case "p": model.peek()
        case "/": model.isSearching = true
        case "a": model.unreadOnly.toggle()
        case "s": model.groupByRepository.toggle()
        case "r": model.refresh()
        case "?": model.overlay = .help
        case "1": model.show(.split(.needsMe))
        case "2": model.show(.split(.team))
        case "3": model.show(.split(.following))
        case "4": model.show(.split(.feed))
        case "5", "6", "7", "8", "9":
            // Saved searches follow the four splits.
            let index = Int(characters)! - 5
            if model.savedSearches.indices.contains(index) { model.show(.saved(model.savedSearches[index].id)) }
        default: return false
        }
        return true
    }
}

/// The snooze choices, each on a digit.
struct SnoozeOption: Identifiable, Sendable {
    let key: String
    let title: String
    let date: @Sendable () -> Date
    var id: String { key }

    static let all: [SnoozeOption] = [
        SnoozeOption(key: "1", title: "In 1 hour") { .now.addingTimeInterval(3600) },
        SnoozeOption(key: "2", title: "In 3 hours") { .now.addingTimeInterval(3 * 3600) },
        SnoozeOption(key: "3", title: "Tomorrow 9:00") { nextMorning(after: .now, weekday: nil) },
        SnoozeOption(key: "4", title: "Monday 9:00") { nextMorning(after: .now, weekday: 2) },
        SnoozeOption(key: "5", title: "In a week") { nextMorning(after: .now.addingTimeInterval(6 * 24 * 3600), weekday: nil) },
    ]

    static func nextMorning(after date: Date, weekday: Int?) -> Date {
        let calendar = Calendar.current
        var components = DateComponents(hour: 9, minute: 0)
        components.weekday = weekday
        return calendar.nextDate(after: calendar.startOfDay(for: date).addingTimeInterval(24 * 3600 - 1), matching: components, matchingPolicy: .nextTime) ?? date.addingTimeInterval(24 * 3600)
    }
}
