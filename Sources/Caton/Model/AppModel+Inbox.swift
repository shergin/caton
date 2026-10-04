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
        case .saved(let id): items = savedItems(id)
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

    /// The rows as the list draws them: headers, threads and, in Feed
    /// without a search, bundles.
    var visibleRows: [ListRow] {
        let bundles = section == .split(.feed) && SearchQuery(searchQuery).isEmpty
        return ListLayout.rows(visibleItems, groupByRepository: groupByRepository, bundles: bundles, expanded: expandedBundles) { [self] item in
            item.classification.actorKind == .bot ? facts(for: item.thread)?.author?.login : nil
        }
    }

    /// The ids selection moves through, in order.
    private var selectableIDs: [String] { visibleRows.filter(\.isSelectable).map(\.id) }

    var needsMeCount: Int { snapshot.count(.needsMe) }

    var selectedItem: InboxItem? { visibleItems.first { $0.id == selectedID } }

    /// The bundle the selection is on, if it is on one.
    var selectedBundle: ThreadBundle? {
        guard let selectedID, ThreadBundle.isBundleID(selectedID) else { return nil }
        for row in visibleRows {
            if case .bundle(let bundle, _) = row, bundle.id == selectedID { return bundle }
        }
        return nil
    }

    func count(_ section: Section) -> Int {
        switch section {
        case .split(let split): snapshot.count(split)
        case .saved(let id): savedItems(id).count
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

    /// The tabs in order: the four splits, then saved searches.
    var tabs: [Section] { Split.allCases.map { .split($0) } + savedSearches.map { .saved($0.id) } }

    func cycleSplit(by offset: Int) {
        let tabs = tabs
        let current = tabs.firstIndex(of: section) ?? -1
        let next = ((current + offset) % tabs.count + tabs.count) % tabs.count
        show(tabs[next])
    }

    // MARK: Saved searches

    var savedSearches: [SavedSearch] {
        _ = settingsVersion
        return state.savedSearches
    }

    func savedSearch(_ id: UUID) -> SavedSearch? { savedSearches.first { $0.id == id } }

    /// Every thread in the four splits that the saved query matches.
    private func savedItems(_ id: UUID) -> [InboxItem] {
        guard let saved = state.savedSearches.first(where: { $0.id == id }) else { return [] }
        let query = SearchQuery(saved.query)
        return Split.allCases.flatMap { snapshot.items(in: $0) }.filter { query.matches($0, facts: facts(for: $0.thread)) }
    }

    /// Asks for a name for the current search.
    func beginSavingSearch() {
        guard !SearchQuery(searchQuery).isEmpty else {
            toast("Type a search first (/), then save it")
            return
        }
        isSearching = false
        overlay = .saveSearch
    }

    /// Keeps the current search as a split and shows it.
    func saveSearch(named name: String) {
        overlay = .none
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        let saved = SavedSearch(name: name.isEmpty ? query : name, query: query)
        state.savedSearches.append(saved)
        searchQuery = ""
        settingsVersion += 1
        save()
        show(.saved(saved.id))
        toast("Saved \(saved.name) as a split")
    }

    func renameSavedSearch(_ id: UUID, to name: String) {
        guard let index = state.savedSearches.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.savedSearches[index].name = name
        settingsVersion += 1
        save()
    }

    func deleteSavedSearch(_ id: UUID) {
        state.savedSearches.removeAll { $0.id == id }
        settingsVersion += 1
        save()
        if section == .saved(id) { show(.split(.needsMe)) }
    }

    /// Selects a row; a thread inside a closed bundle opens the bundle.
    func select(_ id: String) {
        var ids = selectableIDs
        if !ids.contains(id), let bundle = bundle(containing: id) {
            expandedBundles.insert(bundle.id)
            ids = selectableIDs
        }
        selectedID = id
        if let index = ids.firstIndex(of: id) { selectedIndexHint = index }
    }

    func moveSelection(by offset: Int) {
        let ids = selectableIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == selectedID } ?? -1
        let index = max(0, min(ids.count - 1, current + offset))
        select(ids[index])
    }

    func selectFirst() { if let first = selectableIDs.first { select(first) } }
    func selectLast() { if let last = selectableIDs.last { select(last) } }

    /// Keeps a selection on screen after the list changes: the same row, the
    /// bundle that took it in, else the row now at its old position.
    func reselect() {
        let ids = selectableIDs
        guard !ids.isEmpty else {
            selectedID = nil
            return
        }
        if let selectedID, let index = ids.firstIndex(of: selectedID) {
            selectedIndexHint = index
            return
        }
        if let selectedID, let bundle = bundle(containing: selectedID), let index = ids.firstIndex(of: bundle.id) {
            self.selectedID = bundle.id
            selectedIndexHint = index
            return
        }
        let index = min(selectedIndexHint, ids.count - 1)
        selectedID = ids[index]
        checked = checked.intersection(Set(visibleItems.map(\.id)))
    }

    // MARK: Bundles

    /// The bundle a thread belongs to in the current layout.
    func bundle(containing id: String) -> ThreadBundle? {
        for row in visibleRows {
            if case .bundle(let bundle, _) = row, bundle.items.contains(where: { $0.id == id }) { return bundle }
        }
        return nil
    }

    func toggleBundle(_ id: String) {
        if expandedBundles.contains(id) { expandedBundles.remove(id) } else { expandedBundles.insert(id) }
        selectedID = id
        reselect()
    }

    /// Right arrow: opens the selected bundle.
    func expandSelection() {
        guard let bundle = selectedBundle, !expandedBundles.contains(bundle.id) else { return }
        toggleBundle(bundle.id)
    }

    /// Left arrow: closes the selected bundle, or the bundle around the
    /// selected thread, and selects it.
    func collapseSelection() {
        guard let selectedID else { return }
        if ThreadBundle.isBundleID(selectedID) {
            if expandedBundles.contains(selectedID) { toggleBundle(selectedID) }
        } else if let bundle = bundle(containing: selectedID) {
            toggleBundle(bundle.id)
        }
    }

    /// Checks a thread for bulk verbs; on a bundle, all of its threads.
    func toggleChecked(_ id: String? = nil) {
        guard let id = id ?? selectedID else { return }
        if ThreadBundle.isBundleID(id) {
            guard let bundle = visibleRows.lazy.compactMap({ row -> ThreadBundle? in
                if case .bundle(let bundle, _) = row, bundle.id == id { return bundle }
                return nil
            }).first else { return }
            let ids = Set(bundle.items.map(\.id))
            if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
            return
        }
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func clearChecked() { checked.removeAll() }

    /// The threads a verb applies to: the checked ones, else the selection,
    /// which on a bundle is all of its threads.
    func targets(_ id: String? = nil) -> [InboxItem] {
        let items = visibleItems
        if let id {
            if ThreadBundle.isBundleID(id) { return bundleItems(id) }
            return items.filter { $0.id == id }
        }
        if !checked.isEmpty { return items.filter { checked.contains($0.id) } }
        if let selectedID, ThreadBundle.isBundleID(selectedID) { return bundleItems(selectedID) }
        return items.filter { $0.id == selectedID }
    }

    private func bundleItems(_ id: String) -> [InboxItem] {
        for row in visibleRows {
            if case .bundle(let bundle, _) = row, bundle.id == id { return bundle.items }
        }
        return []
    }

    // MARK: Verbs

    /// Opens the selection in the browser and marks it read at once.
    /// On a bundle, opens or closes it instead, and the panel stays.
    @discardableResult
    func open(_ id: String? = nil) -> Bool {
        if checked.isEmpty, let bundleID = id ?? selectedID, ThreadBundle.isBundleID(bundleID) {
            toggleBundle(bundleID)
            return false
        }
        let items = targets(id)
        guard !items.isEmpty else { return false }
        for item in items {
            // Practice threads have no page on GitHub.
            if !isPractice { openURL(item.thread.webURL) }
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
        state.count(byYou: items.count, now: .now)
        undoStack.append(.queued(batch))
        checked.removeAll()
        toast(items.count == 1 ? "\(verbTitle) \(items[0].thread.reference) · z to undo" : "\(verbTitle) \(items.count) threads · z to undo")
        recompute()
        wakeDispatcher()
    }

    /// Hides the selection until a time. With `onlyIfQuiet` it comes back
    /// on any new activity, and at the time only if nothing happened.
    func snooze(_ id: String? = nil, until: Date, onlyIfQuiet: Bool = false) {
        let items = targets(id)
        guard !items.isEmpty else { return }
        var previous: [String: Snooze?] = [:]
        for item in items {
            previous[item.id] = state.snoozes[item.id]
            state.snoozes[item.id] = Snooze(until: until, activity: item.thread.updatedAt, onlyIfQuiet: onlyIfQuiet)
            wokenSnoozes[item.id] = nil
        }
        undoStack.append(.snoozed(previous))
        checked.removeAll()
        let when = until.formatted(.relative(presentation: .named))
        let what = items.count == 1 ? items[0].thread.reference : "\(items.count) threads"
        toast(onlyIfQuiet ? "Reminding about \(what) \(when) if nothing happens · z to undo" : "Snoozed \(what) until \(when) · z to undo")
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

    /// Opens the snooze picker. On the user's own pull request the reminder
    /// defaults to waiting for silence: a follow-up if no one answers.
    func beginSnooze(_ id: String? = nil) {
        if let id { select(id) }
        guard let item = selectedItem else { return }
        snoozeOnlyIfQuiet = item.classification.badge == .author
        overlay = .snooze
    }

    func explain() {
        guard selectedItem != nil else { return }
        overlay = .why
    }

    func peek() {
        guard selectedItem != nil else { return }
        overlay = .peek
    }

    // MARK: Rules

    func isEnabled(_ rule: Rule) -> Bool {
        _ = settingsVersion
        return state.settings.enabledRules.contains(rule)
    }

    func setEnabled(_ rule: Rule, _ enabled: Bool) {
        if enabled { state.settings.enabledRules.insert(rule) } else { state.settings.enabledRules.remove(rule) }
        settingsChanged()
    }

    /// Reclassifies after a settings change and lets settings views redraw.
    private func settingsChanged() {
        settingsVersion += 1
        recompute()
    }

    var mutedRepositories: [String] {
        _ = settingsVersion
        return state.settings.mutedRepositories.sorted()
    }

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

    func logins(_ list: LoginList) -> [String] {
        _ = settingsVersion
        return state.settings[keyPath: list.keyPath].sorted()
    }

    func addLogin(_ login: String, to list: LoginList) {
        let login = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard !login.isEmpty else { return }
        state.settings[keyPath: list.keyPath].insert(login)
        settingsChanged()
    }

    func removeLogin(_ login: String, from list: LoginList) {
        state.settings[keyPath: list.keyPath].remove(login)
        settingsChanged()
    }

    /// How many days read threads outside Needs me stay.
    var readWindowDays: Int {
        get {
            _ = settingsVersion
            return state.settings.readWindowDays
        }
        set {
            state.settings.readWindowDays = min(max(newValue, 1), 30)
            settingsChanged()
        }
    }

    /// The last seven days' clears, for Settings' About tab.
    var weekTally: Tally {
        _ = snapshot
        return state.week(now: .now)
    }

    func unmute(_ repository: String) {
        state.settings.mutedRepositories.remove(repository)
        settingsChanged()
    }

    func muteRepository(_ id: String? = nil) {
        guard let item = targets(id).first else { return }
        state.settings.mutedRepositories.insert(item.thread.repository.fullName.lowercased())
        toast("Muted \(item.thread.repository.fullName)")
        settingsChanged()
    }

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
        let splits: [Split] = if case .split(let split) = section, split != .needsMe { [split] } else { [.team, .following, .feed] }
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
        overlay = .none
        let items = option.items.filter { $0.classification.split != .needsMe }
        guard !items.isEmpty else { return }
        let batch = state.queue.enqueue(.done, items.map { .init(threadID: $0.id, activity: $0.thread.updatedAt, subjectNodeID: facts(for: $0.thread)?.nodeID) }, now: .now, grace: Self.grace)
        state.cleared += items.map { ClearedEntry(batch: batch, thread: $0.thread, rule: nil, at: .now) }
        state.count(byYou: items.count, now: .now)
        undoStack.append(.queued(batch))
        checked.removeAll()
        toast("Cleared \(items.count) · z to undo")
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
        let dismissals = removed.filter(\.verb.dismisses)
        let byRules = dismissals.filter { $0.rule != nil }.count
        state.count(byRules: -byRules, byYou: -(dismissals.count - byRules), now: .now)
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
