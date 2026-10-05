import AppKit
import CatonCore

extension InboxItem {
    /// Whether the row is a reminder Caton made, which verbs settle locally.
    var isReminder: Bool {
        if case .followUp = id { return true }
        return false
    }
}

/// What the list shows, moving through it, and the verbs.
extension AppModel {
    // MARK: What the list shows

    /// The current section's threads and rows, and what they were computed
    /// from. Everything a keystroke reads (the selection's neighbours, the
    /// rows to draw, the bundle under the selection) reads this.
    struct ListCache {
        struct Key: Equatable {
            var session: ObjectIdentifier?
            var snapshot: Int
            var savedSearches: [SavedSearch]
            var section: Section
            var query: String
            var unreadOnly: Bool
            var grouped: Bool
            var expanded: Set<ThreadBundle.Kind>
        }

        let key: Key
        let items: [InboxItem]
        let rows: [ListRow]
    }

    struct SavedCountKey: Equatable {
        var session: ObjectIdentifier?
        var snapshot: Int
        var savedSearches: [SavedSearch]
    }

    /// The rows of the current section, filtered and in display order.
    var visibleItems: [InboxItem] { list.items }

    /// The rows as the list draws them: headers, threads and, in Feed
    /// without a search, bundles.
    var visibleRows: [ListRow] { list.rows }

    /// The list for the current inputs: from the cache when they have not
    /// changed. Reading the inputs here is what lets views observe them.
    private var list: ListCache {
        _ = inbox?.snapshot
        let key = ListCache.Key(
            session: inbox.map(ObjectIdentifier.init),
            snapshot: inbox?.snapshotVersion ?? 0,
            savedSearches: savedSearches,
            section: section,
            query: searchQuery,
            unreadOnly: unreadOnly,
            grouped: groupByRepository,
            expanded: expandedBundles
        )
        if let listCache, listCache.key == key { return listCache }
        let items = layoutItems()
        let bundles = section == .split(.feed) && SearchQuery(searchQuery).isEmpty
        let rows = ListLayout.rows(items, groupByRepository: groupByRepository, bundles: bundles, expanded: expandedBundles) { [self] item in
            item.classification.actorKind == .bot ? facts(for: item.id)?.author?.login : nil
        }
        let cache = ListCache(key: key, items: items, rows: rows)
        listCache = cache
        return cache
    }

    private func layoutItems() -> [InboxItem] {
        guard let inbox else { return [] }
        var items: [InboxItem]
        switch section {
        case .split(let split): items = inbox.snapshot.items(in: split)
        case .saved(let id): items = inbox.savedSearch(id).map(inbox.items(matching:)) ?? []
        case .myPullRequests: items = []
        case .snoozed: items = inbox.snapshot.snoozed
        case .later: items = inbox.snapshot.later
        case .cleared: items = []
        }
        if unreadOnly { items = items.filter(\.isUnread) }
        let query = SearchQuery(searchQuery)
        if !query.isEmpty {
            items = items.filter { query.matches($0, facts: facts(for: $0.id)) }
        }
        guard groupByRepository else { return items }
        // Repository order holds while the panel is open, so rows do not jump.
        var rank = Dictionary(repositoryOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items where rank[item.thread.repository] == nil {
            rank[item.thread.repository] = repositoryOrder.count
            repositoryOrder.append(item.thread.repository)
        }
        // Sort positions, not the items themselves: an item is large.
        let ranks = items.map { rank[$0.thread.repository] ?? .max }
        return items.indices
            .sorted { ranks[$0] == ranks[$1] ? $0 < $1 : ranks[$0] < ranks[$1] }
            .map { items[$0] }
    }

    /// The rows selection moves through, in order.
    private var selectableIDs: [RowID] {
        if section == .myPullRequests { return myPullRequestNodes.map { .pullRequest($0.id) } }
        return visibleRows.filter(\.isSelectable).map(\.id)
    }

    var selectedItem: InboxItem? {
        guard let id = selectedID?.item else { return nil }
        return visibleItems.first { $0.id == id }
    }

    /// The bundle the selection is on, if it is on one.
    var selectedBundle: ThreadBundle? {
        guard case .bundle(let kind) = selectedID else { return nil }
        return bundle(kind)
    }

    func count(_ section: Section) -> Int {
        switch section {
        case .split(let split): snapshot.count(split)
        case .saved(let id): savedCount(id)
        case .myPullRequests: myPullRequestNodes.count
        case .snoozed: snapshot.snoozed.count
        case .later: snapshot.later.count
        case .cleared: inbox?.state.cleared.count ?? 0
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

    /// Selects a row; a thread inside a closed bundle opens the bundle.
    func select(_ id: RowID) {
        var ids = selectableIDs
        if !ids.contains(id), let item = id.item, let bundle = bundle(containing: item) {
            expandedBundles.insert(bundle.kind)
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
        if let item = selectedID?.item, let bundle = bundle(containing: item), let index = ids.firstIndex(of: .bundle(bundle.kind)) {
            selectedID = .bundle(bundle.kind)
            selectedIndexHint = index
            return
        }
        let index = min(selectedIndexHint, ids.count - 1)
        selectedID = ids[index]
        checked = checked.intersection(Set(visibleItems.map(\.id)))
    }

    // MARK: Bundles

    /// The bundle of a kind in the current layout.
    func bundle(_ kind: ThreadBundle.Kind) -> ThreadBundle? {
        for row in visibleRows {
            if case .bundle(let bundle, _) = row, bundle.kind == kind { return bundle }
        }
        return nil
    }

    /// The bundle a thread belongs to in the current layout.
    func bundle(containing id: ItemID) -> ThreadBundle? {
        for row in visibleRows {
            if case .bundle(let bundle, _) = row, bundle.items.contains(where: { $0.id == id }) { return bundle }
        }
        return nil
    }

    func toggleBundle(_ kind: ThreadBundle.Kind) {
        if expandedBundles.contains(kind) { expandedBundles.remove(kind) } else { expandedBundles.insert(kind) }
        selectedID = .bundle(kind)
        reselect()
    }

    /// Right arrow: opens the selected bundle.
    func expandSelection() {
        guard let bundle = selectedBundle, !expandedBundles.contains(bundle.kind) else { return }
        toggleBundle(bundle.kind)
    }

    /// Left arrow: closes the selected bundle, or the bundle around the
    /// selected thread, and selects it.
    func collapseSelection() {
        switch selectedID {
        case .bundle(let kind):
            if expandedBundles.contains(kind) { toggleBundle(kind) }
        case .item(let item):
            if let bundle = bundle(containing: item) { toggleBundle(bundle.kind) }
        case .header, .pullRequest, nil:
            break
        }
    }

    /// Checks a thread for bulk verbs; on a bundle, all of its threads.
    func toggleChecked(_ id: RowID? = nil) {
        switch id ?? selectedID {
        case .bundle(let kind):
            guard let bundle = bundle(kind) else { return }
            let ids = Set(bundle.items.map(\.id))
            if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
        case .item(let item):
            if checked.contains(item) { checked.remove(item) } else { checked.insert(item) }
        case .header, .pullRequest, nil:
            break
        }
    }

    func clearChecked() { checked.removeAll() }

    /// The rows a verb applies to: the checked ones, else the selection,
    /// which on a bundle is all of its threads.
    func targets(_ id: RowID? = nil) -> [InboxItem] {
        let items = visibleItems
        if id == nil, !checked.isEmpty { return items.filter { checked.contains($0.id) } }
        switch id ?? selectedID {
        case .bundle(let kind): return bundle(kind)?.items ?? []
        case .item(let item): return items.filter { $0.id == item }
        case .header, .pullRequest, nil: return []
        }
    }

    // MARK: Verbs

    /// Opens the selection in the browser and marks it read at once.
    /// On a bundle, opens or closes it instead, and the panel stays.
    @discardableResult
    func open(_ id: RowID? = nil) -> Bool {
        switch id ?? selectedID {
        case .pullRequest(let pullRequestID):
            openPullRequest(pullRequestID)
            return true
        case .bundle(let kind) where checked.isEmpty:
            toggleBundle(kind)
            return false
        default:
            break
        }
        let items = targets(id)
        guard let inbox, !items.isEmpty else { return false }
        // The practice inbox's threads have no page on GitHub.
        if !inbox.isPractice { for item in items { openURL(item.thread.webURL) } }
        inbox.markRead(items)
        checked.removeAll()
        toast(items.count == 1 ? "Opened \(items[0].thread.reference)" : "Opened \(items.count) threads")
        return true
    }

    func markRead(_ id: RowID? = nil) {
        inbox?.markRead(targets(id))
        checked.removeAll()
    }

    func done(_ id: RowID? = nil) { dismiss(.done, id, verbTitle: "Done") }
    func unsubscribe(_ id: RowID? = nil) { dismiss(.unsubscribe, id, verbTitle: "Unsubscribed") }
    func ignore(_ id: RowID? = nil) { dismiss(.ignore, id, verbTitle: "Ignored") }

    /// Done, unsubscribe or ignore. A reminder row is Caton's own: the verb
    /// ends the reminder instead.
    private func dismiss(_ verb: Verb, _ id: RowID?, verbTitle: String) {
        guard let inbox else { return }
        let items = targets(id)
        guard !items.isEmpty else { return }
        checked.removeAll()
        let reminders = items.filter(\.isReminder)
        let rows = items.filter { !$0.isReminder }
        if let undo = inbox.settleReminders(reminders) { undoStack.append(undo) }
        guard !rows.isEmpty else {
            toast(reminders.count == 1 ? "Reminder done · z to undo" : "\(reminders.count) reminders done · z to undo")
            return
        }
        undoStack.append(inbox.dismiss(verb, rows))
        toast(rows.count == 1 ? "\(verbTitle) \(rows[0].thread.reference) · z to undo" : "\(verbTitle) \(rows.count) threads · z to undo")
    }

    /// Hides the selection until a time. With `onlyIfQuiet` it comes back
    /// on any new activity, and at the time only if nothing happened. A
    /// reminder row moves its reminder.
    func snooze(_ id: RowID? = nil, until: Date, onlyIfQuiet: Bool = false) {
        guard let inbox else { return }
        let items = targets(id)
        guard !items.isEmpty else { return }
        checked.removeAll()
        let when = until.formatted(.relative(presentation: .named))
        let reminders = items.filter(\.isReminder)
        let rows = items.filter { !$0.isReminder }
        if let undo = inbox.settleReminders(reminders, until: until) { undoStack.append(undo) }
        guard !rows.isEmpty else {
            toast("Reminding \(when) · z to undo")
            return
        }
        undoStack.append(inbox.snooze(rows, until: until, onlyIfQuiet: onlyIfQuiet))
        let what = rows.count == 1 ? rows[0].thread.reference : "\(rows.count) threads"
        toast(onlyIfQuiet ? "Reminding about \(what) \(when) if nothing happens · z to undo" : "Snoozed \(what) until \(when) · z to undo")
    }

    func toggleLater(_ id: RowID? = nil) {
        guard let inbox else { return }
        let items = targets(id)
        guard !items.isEmpty else { return }
        let (undo, added) = inbox.toggleLater(items)
        undoStack.append(undo)
        checked.removeAll()
        toast(added ? "Saved for later · z to undo" : "Removed from Later")
    }

    /// Opens the snooze picker. On the user's own pull request the reminder
    /// defaults to waiting for silence: a follow-up if no one answers.
    func beginSnooze(_ id: RowID? = nil) {
        if case .pullRequest(let pullRequestID) = id ?? selectedID {
            beginReminder(pullRequestID)
            return
        }
        snoozeTarget = .threads
        if let id { select(id) }
        guard let item = selectedItem else { return }
        snoozeOnlyIfQuiet = item.classification.badge == .author
        overlay = .snooze
    }

    /// What a choice in the snooze picker does: snooze the threads, or set
    /// the reminder on a pull request.
    func chooseSnooze(_ until: Date) {
        overlay = .none
        switch snoozeTarget {
        case .threads: snooze(until: until, onlyIfQuiet: snoozeOnlyIfQuiet)
        case .pullRequest(let id): remind(id, until: until)
        }
    }

    func explain() {
        guard selectedItem != nil else { return }
        overlay = .why
    }

    func peek() {
        guard selectedItem != nil else { return }
        overlay = .peek
    }

    func muteRepository(_ id: RowID? = nil) {
        guard let item = targets(id).first else { return }
        inbox?.mute(item.thread.repository)
        toast("Muted \(item.thread.repository.fullName)")
    }

    func copyLink(_ id: RowID? = nil) {
        if case .pullRequest(let pullRequestID) = id ?? selectedID {
            copyPullRequestLink(pullRequestID)
            return
        }
        guard let item = targets(id).first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.thread.webURL.absoluteString, forType: .string)
        toast("Copied \(item.thread.reference)")
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
        guard let inbox, !items.isEmpty else { return }
        undoStack.append(inbox.clear(items))
        checked.removeAll()
        toast("Cleared \(items.count) · z to undo")
    }

    // MARK: Undo

    func undo() {
        guard let inbox else { return }
        let undone: Session.Undone
        if let entry = undoStack.popLast() {
            undone = inbox.undo(entry)
        } else if let latest = inbox.undoLatestQueued() {
            undone = latest
        } else {
            toast("Nothing to undo")
            return
        }
        if let item = undone.select { selectedID = .item(item) }
        toast(undone.message)
    }

    /// Lets a cleared thread back in, for this activity.
    func restore(_ entry: ClearedEntry) {
        guard let inbox else { return }
        toast(inbox.restore(entry))
    }

    // MARK: Saved searches

    var savedSearches: [SavedSearch] { inbox?.savedSearches ?? [] }

    func savedSearch(_ id: UUID) -> SavedSearch? { inbox?.savedSearch(id) }

    /// How many threads a saved search matches; every saved search is
    /// counted once per change to the inbox, not once per redraw.
    private func savedCount(_ id: UUID) -> Int {
        guard let inbox else { return 0 }
        _ = inbox.snapshot
        let key = SavedCountKey(session: ObjectIdentifier(inbox), snapshot: inbox.snapshotVersion, savedSearches: inbox.savedSearches)
        if let savedCountCache, savedCountCache.key == key { return savedCountCache.counts[id] ?? 0 }
        let counts = Dictionary(uniqueKeysWithValues: inbox.savedSearches.map { ($0.id, inbox.items(matching: $0).count) })
        savedCountCache = (key, counts)
        return counts[id] ?? 0
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
        guard let inbox, !query.isEmpty else { return }
        let saved = inbox.addSavedSearch(named: name.trimmingCharacters(in: .whitespaces), query: query)
        searchQuery = ""
        show(.saved(saved.id))
        toast("Saved \(saved.name) as a split")
    }

    func renameSavedSearch(_ id: UUID, to name: String) { inbox?.renameSavedSearch(id, to: name) }

    func deleteSavedSearch(_ id: UUID) {
        inbox?.deleteSavedSearch(id)
        if section == .saved(id) { show(.split(.needsMe)) }
    }
}
