import CatonCore
import Foundation

/// Changes to the inbox: verbs on its rows, rules and lists, saved searches,
/// and the undo each change can be taken back by. Every change that reaches
/// GitHub goes through the action queue and its grace window.
extension Session {
    /// One step undo can take back.
    enum Undo {
        case queued(UUID)
        case snoozed([ItemID: Snooze?])
        case later([ItemID: Date?])
        case followUps([String: FollowUp?])
        /// A write to a pull request still in its undo window, by node id.
        case pullRequestWrite(String)
    }

    /// What an undo did: what to say, and the row to select.
    struct Undone {
        let message: String
        var select: ItemID?
    }

    // MARK: Verbs

    /// Marks rows read: here at once, on GitHub as soon as the dispatcher
    /// runs. Only a thread has a read state on GitHub.
    func markRead(_ items: [InboxItem]) {
        let threads = items.filter { $0.isUnread && $0.id.isThread }
        guard !threads.isEmpty else { return }
        for item in threads { state.readMarks[item.id] = item.thread.updatedAt }
        state.queue.enqueue(.markRead, threads.map { .init(item: $0.id, activity: $0.thread.updatedAt) }, now: .now, grace: 0)
        recompute()
        wakeDispatcher()
    }

    /// Done, unsubscribe or ignore, after the grace window. A review request
    /// is dismissed here alone; reminders are settled, not dismissed.
    func dismiss(_ verb: Verb, _ items: [InboxItem]) -> Undo {
        let batch = state.queue.enqueue(verb, items.map { .init(item: $0.id, activity: $0.thread.updatedAt, subjectNodeID: facts(for: $0.id)?.nodeID) }, now: .now, grace: Self.grace)
        state.count(byYou: items.count, now: .now)
        recompute()
        wakeDispatcher()
        return .queued(batch)
    }

    /// Hides rows until a time. With `onlyIfQuiet` they come back on any new
    /// activity, and at the time only if nothing happened.
    func snooze(_ items: [InboxItem], until: Date, onlyIfQuiet: Bool) -> Undo {
        var previous: [ItemID: Snooze?] = [:]
        for item in items {
            previous[item.id] = state.snoozes[item.id]
            state.snoozes[item.id] = Snooze(until: until, activity: item.thread.updatedAt, onlyIfQuiet: onlyIfQuiet)
            wokenSnoozes[item.id] = nil
        }
        recompute()
        return .snoozed(previous)
    }

    /// Saves rows for later, or takes them back out when all already are.
    func toggleLater(_ items: [InboxItem]) -> (undo: Undo, added: Bool) {
        var previous: [ItemID: Date?] = [:]
        let adding = items.contains { state.later[$0.id] == nil }
        for item in items {
            previous[item.id] = state.later[item.id]
            state.later[item.id] = adding ? .now : nil
        }
        recompute()
        return (.later(previous), adding)
    }

    /// Done for every row of a bulk clear, as one batch logged in Cleared.
    func clear(_ items: [InboxItem]) -> Undo {
        let batch = state.queue.enqueue(.done, items.map { .init(item: $0.id, activity: $0.thread.updatedAt, subjectNodeID: facts(for: $0.id)?.nodeID) }, now: .now, grace: Self.grace)
        state.cleared += items.map { ClearedEntry(batch: batch, thread: $0.thread, rule: nil, at: .now) }
        state.count(byYou: items.count, now: .now)
        recompute()
        wakeDispatcher()
        return .queued(batch)
    }

    // MARK: Undo

    func undo(_ entry: Undo) -> Undone {
        switch entry {
        case .queued(let batch):
            return undoQueued(batch)
        case .snoozed(let previous):
            for (id, snooze) in previous { state.snoozes[id] = snooze }
            recompute()
            return Undone(message: "Snooze undone")
        case .later(let previous):
            for (id, date) in previous { state.later[id] = date }
            recompute()
            return Undone(message: "Undone")
        case .followUps(let previous):
            for (id, followUp) in previous { state.followUps[id] = followUp }
            recompute()
            return Undone(message: "Undone")
        case .pullRequestWrite(let pullRequestID):
            guard let kind = cancelWrite(pullRequestID) else { return Undone(message: "Already sent to GitHub") }
            return Undone(message: kind == .readyForReview ? "Still a draft" : "Nudge cancelled")
        }
    }

    /// Takes back the latest batch still waiting, when the undo stack is
    /// empty (it does not outlive a relaunch; the queue does).
    func undoLatestQueued() -> Undone? {
        state.queue.lastUndoableBatch.map(undoQueued)
    }

    private func undoQueued(_ batch: UUID) -> Undone {
        let removed = state.queue.undo(batch: batch)
        guard !removed.isEmpty else { return Undone(message: "Already sent to GitHub") }
        state.cleared.removeAll { $0.batch == batch }
        let dismissals = removed.filter(\.verb.dismisses)
        let byRules = dismissals.filter { $0.rule != nil }.count
        state.count(byRules: -byRules, byYou: -(dismissals.count - byRules), now: .now)
        for action in removed where action.rule != nil {
            state.ruleExemptions[action.item] = action.activity
        }
        recompute()
        return Undone(message: removed.count == 1 ? "Undone" : "Undone for \(removed.count) threads", select: removed.first?.item)
    }

    /// Lets a cleared thread back in, for this activity.
    func restore(_ entry: ClearedEntry) -> String {
        let removed = state.queue.undo(batch: entry.batch).filter { $0.item == entry.item }
        if case .rule? = state.dismissals[entry.item]?.cause { state.dismissals[entry.item] = nil }
        let latest = if case .thread(let id) = entry.item { threads[id]?.updatedAt } else { nil as Date? }
        state.ruleExemptions[entry.item] = latest ?? .now
        state.cleared.removeAll { $0.id == entry.id }
        recompute()
        return removed.isEmpty && state.dismissals[entry.item] != nil ? "Already done on GitHub" : "Restored \(entry.reference)"
    }

    /// Rule clears so far stayed local; now they reach GitHub too, but only
    /// where the clear still covers the thread's latest activity.
    func syncRuleClearsToGitHub() {
        let targets = state.dismissals.compactMap { id, dismissal -> ActionQueue.Target? in
            guard case .rule = dismissal.cause, case .thread(let threadID) = id, let thread = threads[threadID], thread.updatedAt <= dismissal.activity else { return nil }
            return ActionQueue.Target(item: id, activity: dismissal.activity)
        }
        guard !targets.isEmpty else { return }
        state.queue.enqueue(.done, targets, now: .now, grace: Self.grace)
        wakeDispatcher()
    }

    /// Records which activity banners have covered.
    func markAlerted(_ alerted: [ItemID: Date]) {
        guard !alerted.isEmpty else { return }
        state.alerted.merge(alerted) { _, new in new }
    }

    // MARK: Rules and lists

    /// The editable lists of machine accounts.
    enum LoginList: CaseIterable {
        case bots
        case aiReviewers
        case agents

        var keyPath: WritableKeyPath<ClassifierSettings, Set<String>> {
            switch self {
            case .bots: \.botLogins
            case .aiReviewers: \.aiReviewerLogins
            case .agents: \.agentLogins
            }
        }
    }

    func isEnabled(_ rule: Rule) -> Bool { state.settings.enabledRules.contains(rule) }

    func setEnabled(_ rule: Rule, _ enabled: Bool) {
        if enabled { state.settings.enabledRules.insert(rule) } else { state.settings.enabledRules.remove(rule) }
        recompute()
    }

    func logins(_ list: LoginList) -> [String] { state.settings[keyPath: list.keyPath].sorted() }

    func addLogin(_ login: String, to list: LoginList) {
        let login = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard !login.isEmpty else { return }
        state.settings[keyPath: list.keyPath].insert(login)
        recompute()
    }

    func removeLogin(_ login: String, from list: LoginList) {
        state.settings[keyPath: list.keyPath].remove(login)
        recompute()
    }

    /// How many days read threads outside Needs me stay.
    var readWindowDays: Int {
        get { state.settings.readWindowDays }
        set {
            state.settings.readWindowDays = min(max(newValue, 1), 30)
            recompute()
        }
    }

    var mutedRepositories: [String] { state.settings.mutedRepositories.sorted() }

    func mute(_ repository: RepositoryName) {
        state.settings.mutedRepositories.insert(repository.fullName.lowercased())
        recompute()
    }

    func unmute(_ repository: String) {
        state.settings.mutedRepositories.remove(repository)
        recompute()
    }

    /// The last seven days' clears, for Settings' About tab.
    var weekTally: Tally { state.week(now: .now) }

    // MARK: Saved searches

    var savedSearches: [SavedSearch] { state.savedSearches }

    func savedSearch(_ id: UUID) -> SavedSearch? { state.savedSearches.first { $0.id == id } }

    func addSavedSearch(named name: String, query: String) -> SavedSearch {
        let saved = SavedSearch(name: name.isEmpty ? query : name, query: query)
        state.savedSearches.append(saved)
        save()
        return saved
    }

    func renameSavedSearch(_ id: UUID, to name: String) {
        guard let index = state.savedSearches.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.savedSearches[index].name = name
        save()
    }

    func deleteSavedSearch(_ id: UUID) {
        state.savedSearches.removeAll { $0.id == id }
        save()
    }

    /// Every row in the four splits that a saved query matches.
    func items(matching saved: SavedSearch) -> [InboxItem] {
        let query = SearchQuery(saved.query)
        return Split.allCases.flatMap { snapshot.items(in: $0) }.filter { query.matches($0, facts: facts(for: $0.id)) }
    }
}
