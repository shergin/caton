import CatonCore
import Foundation

/// What a row is, for which commands apply to it.
enum RowKind: Hashable {
    case thread
    case reviewRequest
    case followUp
    case bundle
    /// One of the viewer's pull requests in My PRs.
    case pullRequest
}

extension Panel {
    /// The kinds of row a command would act on: the checked rows', else the
    /// selected row's.
    var selectionKinds: Set<RowKind> {
        if !checked.isEmpty { return Set(checked.map(\.kind)) }
        switch selectedID {
        case .item(let id): return [id.kind]
        case .bundle: return [.bundle]
        case .pullRequest: return [.pullRequest]
        case .header, nil: return []
        }
    }
}

extension ItemID {
    var kind: RowKind {
        switch self {
        case .thread: .thread
        case .reviewRequest: .reviewRequest
        case .followUp: .followUp
        }
    }
}

/// One thing the user can do, the keys that do it, and the rows it applies
/// to. This table is the one place keys are bound: the key router runs it,
/// the command menu lists it, and the keymap, Settings and the footer read
/// their shortcuts from it.
@MainActor
struct Command: Identifiable {
    enum Group: CaseIterable {
        case act, move, go, view, app

        var title: String {
            switch self {
            case .act: "Act"
            case .move: "Move"
            case .go: "Go to"
            case .view: "View"
            case .app: "Caton"
            }
        }
    }

    /// Where the command applies.
    enum Scope {
        /// Always.
        case anywhere
        /// When every row it would act on is one of these kinds.
        case rows(Set<RowKind>)
        /// When the panel is in some state, such as on a saved split.
        case when(@MainActor (Panel) -> Bool)
    }

    let id: String
    let title: String
    let group: Group
    let bindings: [KeyBinding]
    let scope: Scope
    /// Navigation repeats while a key is held; everything else fires once
    /// per press, so holding `d` never empties the inbox.
    let repeats: Bool
    /// A short label for the footer, on the commands worth teaching there.
    let hint: String?
    /// Whether the command menu lists it.
    let isListed: Bool
    /// Runs the command; true closes the panel.
    let run: (AppModel) -> Bool

    init(
        _ id: String,
        _ title: String,
        _ group: Group,
        keys bindings: [KeyBinding] = [],
        on scope: Scope = .anywhere,
        repeats: Bool = false,
        hint: String? = nil,
        isListed: Bool = true,
        run: @escaping (AppModel) -> Bool
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.bindings = bindings
        self.scope = scope
        self.repeats = repeats
        self.hint = hint
        self.isListed = isListed
        self.run = run
    }

    /// The keys as the keymap writes them: `e  d`.
    var keys: String { bindings.map(\.label).joined(separator: "  ") }

    func isAvailable(in model: AppModel) -> Bool {
        switch scope {
        case .anywhere:
            return true
        case .rows(let kinds):
            let selection = model.panel.selectionKinds
            return !selection.isEmpty && selection.isSubset(of: kinds)
        case .when(let applies):
            return applies(model.panel)
        }
    }

    /// The first command bound to a key that applies now, and whether any
    /// command is bound to it at all.
    static func match(_ key: KeyPress, afterG: Bool, in model: AppModel) -> (command: Command?, isBound: Bool) {
        let bound = all.filter { $0.bindings.contains { $0.matches(key, afterG: afterG) } }
        return (bound.first { $0.isAvailable(in: model) }, !bound.isEmpty)
    }

    /// What the command menu offers: the listed commands that apply now.
    static func menu(in model: AppModel) -> [Command] {
        all.filter { $0.isListed && $0.isAvailable(in: model) }
    }

    /// The footer's hints: the verbs worth teaching that apply to the
    /// selection, in the table's order.
    static func hints(in model: AppModel, limit: Int) -> [(key: String, label: String)] {
        all.filter { $0.group == .act && $0.hint != nil && $0.isAvailable(in: model) }
            .prefix(limit)
            .map { ($0.bindings.first?.label ?? "", $0.hint ?? "") }
    }

    /// The keymap's lines for a group: each bound command once, and the
    /// commands that share a title (one verb on several kinds of row) on
    /// one line, with at most `keys` of its keys.
    static func keymap(_ group: Group, keys limit: Int = .max) -> [(keys: String, title: String)] {
        var lines: [(keys: [String], title: String)] = []
        for command in all where command.group == group && !command.bindings.isEmpty {
            let labels = command.bindings.map(\.label)
            if let index = lines.firstIndex(where: { $0.title == command.title }) {
                lines[index].keys += labels.filter { !lines[index].keys.contains($0) }
            } else {
                lines.append((labels, command.title))
            }
        }
        return lines.map { line in
            // A run of digits reads as a range: 5–9.
            if line.keys.count > 2, let first = line.keys.first.flatMap(Int.init), line.keys.compactMap(Int.init) == Array(first..<first + line.keys.count) {
                return ("\(first)–\(first + line.keys.count - 1)", line.title)
            }
            return (line.keys.prefix(limit).joined(separator: "  "), line.title)
        }
    }

    /// The commands with no key, which only the command menu runs.
    static var unbound: [Command] { all.filter { $0.isListed && $0.bindings.isEmpty } }
}

// MARK: The table

private let items: Set<RowKind> = [.thread, .reviewRequest, .followUp]
private let page = 8

extension Command {
    /// Every command, in the order the command menu lists them and the
    /// footer picks its hints. One key can serve several commands as long
    /// as their rows differ: `h` snoozes a thread and sets a reminder on a
    /// pull request.
    static let all: [Command] = [
        // Act
        Command("done", "Done", .act, keys: [.character("e"), .character("d")], on: .rows(items.union([.bundle])), hint: "done") { model in model.done(); return false },
        Command("snooze", "Snooze…", .act, keys: [.character("h")], on: .rows(items), hint: "snooze") { model in model.beginSnooze(); return false },
        Command("remind", "Remind me if nobody answers…", .act, keys: [.character("h")], on: .rows([.pullRequest]), hint: "remind") { model in model.beginReminder(); return false },
        Command("nudge", "Nudge the reviewers again", .act, keys: [.character("n")], on: .rows([.pullRequest, .followUp]), hint: "nudge") { model in model.nudge(); return false },
        Command("open", "Open in browser", .act, keys: [.special(.enter), .character("o")], on: .rows(items), hint: "open") { $0.open() },
        Command("open-pull-request", "Open in browser", .act, keys: [.special(.enter), .character("o")], on: .rows([.pullRequest]), hint: "open") { model in model.openPullRequest(); return true },
        Command("toggle-bundle", "Open or close the bundle", .act, keys: [.special(.enter), .character("o")], on: .rows([.bundle]), hint: "open bundle") { model in
            if let bundle = model.panel.selectedBundle { model.panel.toggleBundle(bundle.kind) }
            return false
        },
        Command("ready", "Mark ready for review", .act, keys: [.character("R")], on: .rows([.pullRequest])) { model in model.markReadyForReview(); return false },
        Command("unsubscribe", "Unsubscribe (mentions still notify)", .act, keys: [.character("u")], on: .rows([.thread, .bundle]), hint: "unsub") { model in model.unsubscribe(); return false },
        Command("ignore", "Ignore thread (never notify)", .act, on: .rows([.thread])) { model in model.ignore(); return false },
        Command("later", "Save for later", .act, keys: [.character("b")], on: .rows([.thread, .reviewRequest])) { model in model.toggleLater(); return false },
        Command("read", "Mark read", .act, keys: [.character("m")], on: .rows([.thread, .bundle])) { model in model.markRead(); return false },
        Command("select", "Select for bulk", .act, keys: [.character("x")], on: .rows(items.union([.bundle])), hint: "select") { model in model.panel.toggleChecked(); return false },
        Command("undo", "Undo", .act, keys: [.character("z"), .shortcut("z", .command)]) { model in model.undo(); return false },
        Command("copy", "Copy link", .act, keys: [.character("y")], on: .rows(items)) { model in model.copyLink(); return false },
        Command("copy-pull-request", "Copy link", .act, keys: [.character("y")], on: .rows([.pullRequest])) { model in model.copyPullRequestLink(); return false },
        Command("peek", "Peek at the latest", .act, keys: [.character("p")], on: .rows(items)) { model in model.peek(); return false },
        Command("why", "Why is this here?", .act, on: .rows(items)) { model in model.explain(); return false },
        Command("mute", "Mute this repository", .act, on: .rows([.thread, .reviewRequest])) { model in model.muteRepository(); return false },
        Command("zero", "Get me to zero…", .act) { model in model.panel.overlay = .zero; return false },

        // Move
        Command("down", "Next row", .move, keys: [.character("j"), .special(.down)], repeats: true, isListed: false) { model in model.panel.moveSelection(by: 1); return false },
        Command("up", "Previous row", .move, keys: [.character("k"), .special(.up)], repeats: true, isListed: false) { model in model.panel.moveSelection(by: -1); return false },
        Command("page-down", "Page down", .move, keys: [.character(" "), .special(.pageDown), .shortcut("f", .control)], repeats: true, isListed: false) { model in model.panel.moveSelection(by: page); return false },
        Command("page-up", "Page up", .move, keys: [.special(.pageUp), .shortcut("b", .control)], repeats: true, isListed: false) { model in model.panel.moveSelection(by: -page); return false },
        Command("half-down", "Half a page down", .move, keys: [.shortcut("d", .control)], repeats: true, isListed: false) { model in model.panel.moveSelection(by: page / 2); return false },
        Command("half-up", "Half a page up", .move, keys: [.shortcut("u", .control)], repeats: true, isListed: false) { model in model.panel.moveSelection(by: -page / 2); return false },
        Command("top", "Top", .move, keys: [.afterG("g"), .special(.home), .special(.up, .command)], isListed: false) { model in model.panel.selectFirst(); return false },
        Command("bottom", "Bottom", .move, keys: [.character("G"), .special(.end), .special(.down, .command)], isListed: false) { model in model.panel.selectLast(); return false },
        Command("expand", "Open the bundle", .move, keys: [.special(.right)], on: .rows([.bundle]), isListed: false) { model in model.panel.expandSelection(); return false },
        Command("collapse", "Close the bundle", .move, keys: [.special(.left)], on: .rows([.bundle, .thread]), isListed: false) { model in model.panel.collapseSelection(); return false },
        Command("next-split", "Next split", .move, keys: [.special(.tab)]) { model in model.panel.cycleSplit(by: 1); return false },
        Command("previous-split", "Previous split", .move, keys: [.special(.tab, .shift)]) { model in model.panel.cycleSplit(by: -1); return false },
        Command("back", "Back: clear, then close", .move, keys: [.special(.escape)], isListed: false) { $0.panel.unwind() },

        // Go to
        Command("needs-me", "Go to Needs me", .go, keys: [.character("1")]) { model in model.panel.show(.split(.needsMe)); return false },
        Command("team", "Go to Team", .go, keys: [.character("2")]) { model in model.panel.show(.split(.team)); return false },
        Command("following", "Go to Following", .go, keys: [.character("3")]) { model in model.panel.show(.split(.following)); return false },
        Command("feed", "Go to Feed", .go, keys: [.character("4")]) { model in model.panel.show(.split(.feed)); return false },
    ] + (5...9).map { digit in
        // Saved searches follow the four splits.
        Command("saved-\(digit)", "Go to a saved split", .go, keys: [.character("\(digit)")], isListed: false) { model in model.panel.showSaved(at: digit - 5); return false }
    } + [
        Command("my-pull-requests", "Go to My pull requests", .go, keys: [.afterG("p")]) { model in model.panel.show(.myPullRequests); return false },
        Command("snoozed", "Go to Snoozed", .go, keys: [.afterG("s")]) { model in model.panel.show(.snoozed); return false },
        Command("later-list", "Go to Later", .go, keys: [.afterG("l")]) { model in model.panel.show(.later); return false },
        Command("cleared", "Go to Cleared", .go, keys: [.afterG("c")]) { model in model.panel.show(.cleared); return false },

        // View
        Command("search", "Search", .view, keys: [.character("/")]) { model in model.panel.isSearching = true; return false },
        Command("save-search", "Save search as a split…", .view) { model in model.beginSavingSearch(); return false },
        Command("delete-search", "Delete this saved split", .view, on: .when { $0.isOnSavedSplit }) { model in
            if case .saved(let id) = model.panel.section { model.deleteSavedSearch(id) }
            return false
        },
        Command("unread", "Unread only", .view, keys: [.character("a")]) { model in model.panel.unreadOnly.toggle(); return false },
        Command("group", "Group by repository", .view, keys: [.character("s")]) { model in model.panel.groupByRepository.toggle(); return false },
        Command("refresh", "Refresh", .view, keys: [.character("r")]) { model in model.inbox?.refresh(); return false },
        Command("commands", "Commands", .view, keys: [.shortcut("k", .command)], isListed: false) { model in model.panel.overlay = .commands; return false },
        Command("keys", "Keyboard shortcuts", .view, keys: [.character("?")]) { model in model.panel.overlay = .help; return false },

        // Caton
        Command("practice", "Practice inbox (made-up threads) / leave it", .app) { model in
            model.isPractice ? model.exitPractice() : model.enterPractice()
            return false
        },
        Command("detach", "Open in a window / back to the menu bar", .app) { model in
            model.preferences.detached ? model.attach?() : model.detach?()
            return false
        },
        Command("switch-account", "Switch to the next account", .app) { model in model.switchToNextAccount(); return false },
        Command("add-account", "Add an account…", .app) { model in model.addAccount(); return false },
        Command("settings", "Settings…", .app, keys: [.shortcut(",", .command)]) { model in model.openSettings?(); return false },
        Command("updates", "Check for updates…", .app) { model in model.checkForUpdates(); return true },
    ]
}
