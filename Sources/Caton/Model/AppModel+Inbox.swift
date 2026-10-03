import AppKit
import CatonCore

/// What the list shows, moving through it, and the verbs.
extension AppModel {
    // MARK: What the list shows

    /// The rows of the current section, filtered and in display order.
    var visibleItems: [InboxItem] {
        var items: [InboxItem]
        switch section {
        case .split(let split): items = snapshot.items(in: split)
        case .snoozed: items = snapshot.snoozed
        case .later: items = snapshot.later
        case .cleared: items = []
        }
        if unreadOnly { items = items.filter(\.isUnread) }
        let query = SearchQuery(searchQuery)
        if !query.isEmpty {
            items = items.filter { query.matches($0, facts: facts(for: $0.thread)) }
        }
        guard groupByRepository else { return items }
        // Repository order holds while the panel is open, so rows do not jump.
        for item in items where !repositoryOrder.contains(item.thread.repository.fullName) {
            repositoryOrder.append(item.thread.repository.fullName)
        }
        let rank = Dictionary(repositoryOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated()
            .sorted { lhs, rhs in
                let left = rank[lhs.element.thread.repository.fullName] ?? .max
                let right = rank[rhs.element.thread.repository.fullName] ?? .max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    var needsMeCount: Int { snapshot.count(.needsMe) }

    var selectedItem: InboxItem? { visibleItems.first { $0.id == selectedID } }

    func count(_ section: Section) -> Int {
        switch section {
        case .split(let split): snapshot.count(split)
        case .snoozed: snapshot.snoozed.count
        case .later: snapshot.later.count
        case .cleared: cleared.count
        }
    }

    // MARK: Navigation

    func show(_ section: Section) {
        self.section = section
        checked.removeAll()
        selectedIndexHint = 0
        selectedID = nil
        reselect()
    }

    func cycleSplit(by offset: Int) {
        let splits = Split.allCases
        let current: Int = if case .split(let split) = section { splits.firstIndex(of: split) ?? 0 } else { -1 }
        let next = (current + offset + splits.count) % splits.count
        show(.split(splits[next]))
    }

    func select(_ id: String) {
        selectedID = id
        if let index = visibleItems.firstIndex(where: { $0.id == id }) { selectedIndexHint = index }
    }

    func moveSelection(by offset: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? -1
        let index = max(0, min(items.count - 1, current + offset))
        select(items[index].id)
    }

    func selectFirst() { if let first = visibleItems.first { select(first.id) } }
    func selectLast() { if let last = visibleItems.last { select(last.id) } }

    /// Keeps a selection on screen after the list changes: the same row, else
    /// the row now at its old position.
    func reselect() {
        let items = visibleItems
        guard !items.isEmpty else {
            selectedID = nil
            return
        }
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            selectedIndexHint = index
            return
        }
        let index = min(selectedIndexHint, items.count - 1)
        selectedID = items[index].id
        checked = checked.intersection(Set(items.map(\.id)))
    }

    func toggleChecked(_ id: String? = nil) {
        guard let id = id ?? selectedID else { return }
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func clearChecked() { checked.removeAll() }

    /// The rows a verb applies to: the checked ones, else the selection.
    func targets(_ id: String? = nil) -> [InboxItem] {
        let items = visibleItems
        if let id { return items.filter { $0.id == id } }
        if !checked.isEmpty { return items.filter { checked.contains($0.id) } }
        return items.filter { $0.id == selectedID }
    }

    // MARK: Verbs

    /// Opens the selection in the browser and marks it read at once.
    @discardableResult
    func open(_ id: String? = nil) -> Bool {
        let items = targets(id)
        guard !items.isEmpty else { return false }
        for item in items {
            NSWorkspace.shared.open(item.thread.webURL)
            if item.isUnread {
                state.readMarks[item.id] = item.thread.updatedAt
                state.queue.enqueue(.markRead, [.init(threadID: item.id, activity: item.thread.updatedAt)], now: .now, grace: 0)
            }
        }
        checked.removeAll()
        toast(items.count == 1 ? "Opened \(items[0].thread.reference)" : "Opened \(items.count) threads")
        recompute()
        return true
    }

    func markRead(_ id: String? = nil) {
        let items = targets(id).filter(\.isUnread)
        guard !items.isEmpty else { return }
        for item in items { state.readMarks[item.id] = item.thread.updatedAt }
        state.queue.enqueue(.markRead, items.map { .init(threadID: $0.id, activity: $0.thread.updatedAt) }, now: .now, grace: 0)
        checked.removeAll()
        recompute()
    }

    func done(_ id: String? = nil) { dismiss(.done, id, verbTitle: "Done") }
    func unsubscribe(_ id: String? = nil) { dismiss(.unsubscribe, id, verbTitle: "Unsubscribed") }
    func ignore(_ id: String? = nil) { dismiss(.ignore, id, verbTitle: "Ignored") }

    private func dismiss(_ verb: Verb, _ id: String?, verbTitle: String) {
        let items = targets(id)
        guard !items.isEmpty else { return }
        let batch = state.queue.enqueue(verb, items.map { .init(threadID: $0.id, activity: $0.thread.updatedAt, subjectNodeID: facts(for: $0.thread)?.nodeID) }, now: .now, grace: Self.grace)
        undoStack.append(.queued(batch))
        checked.removeAll()
        toast(items.count == 1 ? "\(verbTitle) \(items[0].thread.reference) · z to undo" : "\(verbTitle) \(items.count) threads · z to undo")
        recompute()
        wakeDispatcher()
    }

    func snooze(_ id: String? = nil, until: Date) {
        let items = targets(id)
        guard !items.isEmpty else { return }
        var previous: [String: Snooze?] = [:]
        for item in items {
            previous[item.id] = state.snoozes[item.id]
            state.snoozes[item.id] = Snooze(until: until, activity: item.thread.updatedAt)
            wokenSnoozes.remove(item.id)
        }
        undoStack.append(.snoozed(previous))
        checked.removeAll()
        let when = until.formatted(.relative(presentation: .named))
        toast(items.count == 1 ? "Snoozed \(items[0].thread.reference) until \(when) · z to undo" : "Snoozed \(items.count) threads · z to undo")
        recompute()
    }

    func toggleLater(_ id: String? = nil) {
        let items = targets(id)
        guard !items.isEmpty else { return }
        var previous: [String: Date?] = [:]
        let adding = items.contains { state.later[$0.id] == nil }
        for item in items {
            previous[item.id] = state.later[item.id]
            state.later[item.id] = adding ? .now : nil
        }
        undoStack.append(.later(previous))
        checked.removeAll()
        toast(adding ? "Saved for later · z to undo" : "Removed from Later")
        recompute()
    }

    func peek() {
        guard selectedItem != nil else { return }
        overlay = .peek
    }

    // MARK: Rules

    func isEnabled(_ rule: Rule) -> Bool { state.settings.enabledRules.contains(rule) }

    func setEnabled(_ rule: Rule, _ enabled: Bool) {
        if enabled { state.settings.enabledRules.insert(rule) } else { state.settings.enabledRules.remove(rule) }
        recompute()
    }

    var mutedRepositories: [String] { state.settings.mutedRepositories.sorted() }

    func unmute(_ repository: String) {
        state.settings.mutedRepositories.remove(repository)
        recompute()
    }

    func muteRepository(_ id: String? = nil) {
        guard let item = targets(id).first else { return }
        state.settings.mutedRepositories.insert(item.thread.repository.fullName.lowercased())
        toast("Muted \(item.thread.repository.fullName)")
        recompute()
    }

    /// Done for everything in Feed, or for everything older than a week in the
    /// current split. Needs me is never cleared in bulk.
    func getMeToZero() {
        guard case .split(let split) = section, split != .needsMe else {
            toast("Needs me is never cleared in bulk")
            return
        }
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 3600)
        let items = split == .feed ? snapshot.items(in: .feed) : snapshot.items(in: split).filter { $0.thread.updatedAt < cutoff }
        guard !items.isEmpty else { return }
        let batch = state.queue.enqueue(.done, items.map { .init(threadID: $0.id, activity: $0.thread.updatedAt) }, now: .now, grace: Self.grace)
        state.cleared += items.map { ClearedEntry(batch: batch, thread: $0.thread, rule: nil, at: .now) }
        undoStack.append(.queued(batch))
        toast("Cleared \(items.count) in \(split.title) · z to undo")
        recompute()
        wakeDispatcher()
    }

    // MARK: Undo

    func undo() {
        guard let entry = undoStack.popLast() else {
            if let batch = state.queue.lastUndoableBatch { undoQueued(batch) } else { toast("Nothing to undo") }
            return
        }
        switch entry {
        case .queued(let batch):
            undoQueued(batch)
        case .snoozed(let previous):
            for (id, snooze) in previous { state.snoozes[id] = snooze }
            toast("Snooze undone")
            recompute()
        case .later(let previous):
            for (id, date) in previous { state.later[id] = date }
            toast("Undone")
            recompute()
        }
    }

    private func undoQueued(_ batch: UUID) {
        let removed = state.queue.undo(batch: batch)
        guard !removed.isEmpty else {
            toast("Already sent to GitHub")
            return
        }
        state.cleared.removeAll { $0.batch == batch }
        for action in removed where action.rule != nil {
            state.ruleExemptions[action.threadID] = action.activity
        }
        if let first = removed.first { selectedID = first.threadID }
        toast(removed.count == 1 ? "Undone" : "Undone for \(removed.count) threads")
        recompute()
    }

    /// Lets a rule-cleared thread back in, for this activity.
    func restore(_ entry: ClearedEntry) {
        let removed = state.queue.undo(batch: entry.batch).filter { $0.threadID == entry.threadID }
        if case .rule? = state.dismissals[entry.threadID]?.cause { state.dismissals[entry.threadID] = nil }
        state.ruleExemptions[entry.threadID] = threads[entry.threadID]?.updatedAt ?? .now
        state.cleared.removeAll { $0.id == entry.id }
        toast(removed.isEmpty && state.dismissals[entry.threadID] != nil ? "Already done on GitHub" : "Restored \(entry.reference)")
        recompute()
    }

    func copyLink(_ id: String? = nil) {
        guard let item = targets(id).first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.thread.webURL.absoluteString, forType: .string)
        toast("Copied \(item.thread.reference)")
    }
}
