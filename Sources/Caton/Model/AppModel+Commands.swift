import AppKit
import CatonCore

extension InboxItem {
    /// Whether the row is a reminder Caton made, which verbs settle locally.
    var isReminder: Bool {
        if case .followUp = id { return true }
        return false
    }
}

/// The verbs views and keys run on the inbox's rows. Each finds its rows in
/// the panel, asks the session to change them (the session keeps the undo)
/// and says what happened. Which verb a key runs on which kind of row is the command
/// table's call (`Command.all`), so a verb here only handles its own kind.
extension AppModel {
    // MARK: Verbs

    /// Opens the selection in the browser and marks it read at once. True
    /// when something opened, and the panel can close.
    @discardableResult
    func open(_ id: RowID? = nil) -> Bool {
        let items = panel.targets(id)
        guard let inbox, !items.isEmpty else { return false }
        // The practice inbox's threads have no page on GitHub.
        if !inbox.isPractice { for item in items { openURL(item.thread.webURL) } }
        inbox.markRead(items)
        panel.clearChecked()
        panel.toast(items.count == 1 ? "Opened \(items[0].thread.reference)" : "Opened \(items.count) threads")
        return true
    }

    func markRead(_ id: RowID? = nil) {
        inbox?.markRead(panel.targets(id))
        panel.clearChecked()
    }

    func done(_ id: RowID? = nil) { dismiss(.done, id, verbTitle: "Done") }
    func unsubscribe(_ id: RowID? = nil) { dismiss(.unsubscribe, id, verbTitle: "Unsubscribed") }
    func ignore(_ id: RowID? = nil) { dismiss(.ignore, id, verbTitle: "Ignored") }

    /// Done, unsubscribe or ignore. A reminder row is Caton's own: the verb
    /// ends the reminder instead.
    private func dismiss(_ verb: Verb, _ id: RowID?, verbTitle: String) {
        guard let inbox else { return }
        let items = panel.targets(id)
        guard !items.isEmpty else { return }
        panel.clearChecked()
        let reminders = items.filter(\.isReminder)
        let rows = items.filter { !$0.isReminder }
        inbox.settleReminders(reminders)
        guard !rows.isEmpty else {
            panel.toast(reminders.count == 1 ? "Reminder done · z to undo" : "\(reminders.count) reminders done · z to undo")
            return
        }
        inbox.dismiss(verb, rows)
        panel.toast(rows.count == 1 ? "\(verbTitle) \(rows[0].thread.reference) · z to undo" : "\(verbTitle) \(rows.count) threads · z to undo")
    }

    /// Hides the selection until a time. With `onlyIfQuiet` it comes back
    /// on any new activity, and at the time only if nothing happened. A
    /// reminder row moves its reminder.
    func snooze(_ id: RowID? = nil, until: Date, onlyIfQuiet: Bool = false) {
        guard let inbox else { return }
        let items = panel.targets(id)
        guard !items.isEmpty else { return }
        panel.clearChecked()
        let when = until.formatted(.relative(presentation: .named))
        let reminders = items.filter(\.isReminder)
        let rows = items.filter { !$0.isReminder }
        inbox.settleReminders(reminders, until: until)
        guard !rows.isEmpty else {
            panel.toast("Reminding \(when) · z to undo")
            return
        }
        inbox.snooze(rows, until: until, onlyIfQuiet: onlyIfQuiet)
        let what = rows.count == 1 ? rows[0].thread.reference : "\(rows.count) threads"
        panel.toast(onlyIfQuiet ? "Reminding about \(what) \(when) if nothing happens · z to undo" : "Snoozed \(what) until \(when) · z to undo")
    }

    func toggleLater(_ id: RowID? = nil) {
        guard let inbox else { return }
        let items = panel.targets(id)
        guard !items.isEmpty else { return }
        let added = inbox.toggleLater(items)
        panel.clearChecked()
        panel.toast(added ? "Saved for later · z to undo" : "Removed from Later")
    }

    /// Opens the snooze picker. On the user's own pull request the reminder
    /// defaults to waiting for silence: a follow-up if no one answers.
    func beginSnooze(_ id: RowID? = nil) {
        panel.snoozeTarget = .threads
        if let id { panel.select(id) }
        guard let item = panel.selectedItem else { return }
        panel.snoozeOnlyIfQuiet = item.classification.badge == .author
        panel.overlay = .snooze
    }

    /// What a choice in the snooze picker does: snooze the threads, or set
    /// the reminder on a pull request.
    func chooseSnooze(_ until: Date) {
        panel.overlay = .none
        switch panel.snoozeTarget {
        case .threads: snooze(until: until, onlyIfQuiet: panel.snoozeOnlyIfQuiet)
        case .pullRequest(let id): remind(id, until: until)
        }
    }

    func explain() {
        guard panel.selectedItem != nil else { return }
        panel.overlay = .why
    }

    func peek() {
        guard panel.selectedItem != nil else { return }
        panel.overlay = .peek
    }

    func muteRepository(_ id: RowID? = nil) {
        guard let item = panel.targets(id).first else { return }
        inbox?.mute(item.thread.repository)
        panel.toast("Muted \(item.thread.repository.fullName)")
    }

    func copyLink(_ id: RowID? = nil) {
        guard let item = panel.targets(id).first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.thread.webURL.absoluteString, forType: .string)
        panel.toast("Copied \(item.thread.reference)")
    }

    // MARK: Get me to zero

    /// One way to clear in bulk, with what it would clear.
    struct ZeroOption: Identifiable {
        let key: String
        let title: String
        let items: [InboxItem]
        var id: String { key }
    }

    /// The bulk clears on offer, each with its count: everything in Feed, or
    /// everything older than a day, three days or a week in the current split
    /// (outside Needs me, in every split but Needs me). Needs me is never
    /// cleared in bulk.
    var zeroOptions: [ZeroOption] {
        let snapshot = inbox?.snapshot ?? InboxSnapshot()
        let splits: [Split] = if case .split(let split) = panel.section, split != .needsMe { [split] } else { [.team, .following, .feed] }
        let scope = splits.count == 1 ? splits[0].title : "Team, Following and Feed"
        let pool = splits.flatMap { snapshot.items(in: $0) }
        let day: TimeInterval = 24 * 3600
        func older(_ days: Double) -> [InboxItem] { pool.filter { $0.thread.updatedAt < .now.addingTimeInterval(-days * day) } }
        return [
            ZeroOption(key: "1", title: "Everything in Feed", items: snapshot.items(in: .feed)),
            ZeroOption(key: "2", title: "Read in \(scope)", items: pool.filter { !$0.isUnread }),
            ZeroOption(key: "3", title: "Older than a day in \(scope)", items: older(1)),
            ZeroOption(key: "4", title: "Older than 3 days in \(scope)", items: older(3)),
            ZeroOption(key: "5", title: "Older than a week in \(scope)", items: older(7)),
        ]
    }

    /// Done for every thread an option covers, as one batch with one undo.
    func getMeToZero(_ option: ZeroOption) {
        panel.overlay = .none
        let items = option.items.filter { $0.classification.split != .needsMe }
        guard let inbox, !items.isEmpty else { return }
        inbox.clear(items)
        panel.clearChecked()
        panel.toast("Cleared \(items.count) · z to undo")
    }

    // MARK: Undo

    /// Takes back the shown session's latest change.
    func undo() {
        guard let undone = inbox?.undo() else {
            panel.toast("Nothing to undo")
            return
        }
        if let item = undone.select { panel.selectedID = .item(item) }
        panel.toast(undone.message)
    }

    /// Lets a cleared thread back in, for this activity.
    func restore(_ entry: ClearedEntry) {
        guard let inbox else { return }
        panel.toast(inbox.restore(entry))
    }

    // MARK: Saved searches

    /// Asks for a name for the current search.
    func beginSavingSearch() {
        guard !SearchQuery(panel.searchQuery).isEmpty else {
            panel.toast("Type a search first (/), then save it")
            return
        }
        panel.isSearching = false
        panel.overlay = .saveSearch
    }

    /// Keeps the current search as a split and shows it.
    func saveSearch(named name: String) {
        panel.overlay = .none
        let query = panel.searchQuery.trimmingCharacters(in: .whitespaces)
        guard let inbox, !query.isEmpty else { return }
        let saved = inbox.addSavedSearch(named: name.trimmingCharacters(in: .whitespaces), query: query)
        panel.inboxChanged()
        panel.searchQuery = ""
        panel.show(.saved(saved.id))
        panel.toast("Saved \(saved.name) as a split")
    }

    func renameSavedSearch(_ id: UUID, to name: String) {
        inbox?.renameSavedSearch(id, to: name)
    }

    func deleteSavedSearch(_ id: UUID) {
        inbox?.deleteSavedSearch(id)
        panel.inboxChanged()
        if panel.section == .saved(id) { panel.show(.split(.needsMe)) }
    }
}
