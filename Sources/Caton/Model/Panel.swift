import CatonCore
import Foundation
import Observation

/// What the panel shows and where the user is in it: the section, the
/// selection and checks, the search and filters, the overlay, and the toasts.
///
/// The list is stored, not computed on read: it is laid out again when what
/// it depends on changes (the session's snapshot, the section, the search,
/// the filters, the open bundles), so the many reads of a keystroke cost
/// nothing and every view that reads it is told when it changes.
@MainActor
@Observable
final class Panel {
    /// What the list shows: a split, a saved search, or one of the local views.
    enum Section: Hashable {
        case split(Split)
        case saved(UUID)
        case myPullRequests
        case snoozed
        case later
        case cleared
    }

    /// A transient layer over the list that takes the keyboard.
    enum Overlay: Equatable {
        case none
        case snooze
        case commands
        case help
        case peek
        case welcome
        case zero
        case why
        case tips
        case saveSearch
    }

    /// What the snooze picker will act on.
    enum SnoozeTarget: Equatable {
        /// The selected or checked threads.
        case threads
        /// A reminder on one of the viewer's pull requests, by node id.
        case pullRequest(String)
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    // MARK: Where the user is

    var section: Section = .split(.needsMe) { didSet { if section != oldValue { relayout() } } }
    var selectedID: RowID?
    var checked: Set<ItemID> = []
    var searchQuery = "" { didSet { if searchQuery != oldValue { relayout() } } }
    var isSearching = false
    var unreadOnly = false { didSet { if unreadOnly != oldValue { relayout() } } }
    var groupByRepository = true { didSet { if groupByRepository != oldValue { relayout() } } }
    /// Feed bundles the user opened.
    var expandedBundles: Set<ThreadBundle.Kind> = [] { didSet { if expandedBundles != oldValue { relayout() } } }
    var overlay: Overlay = .none
    /// The snooze picker's mode: come back only if nothing happens.
    var snoozeOnlyIfQuiet = false
    var snoozeTarget: SnoozeTarget = .threads
    private(set) var toasts: [Toast] = []

    // MARK: The list, laid out

    /// The current section's rows, filtered and in display order.
    private(set) var items: [InboxItem] = []
    /// The rows as the list draws them: headers, threads and, in Feed
    /// without a search, bundles.
    private(set) var rows: [ListRow] = []
    /// How many rows each saved search matches.
    private(set) var savedCounts: [UUID: Int] = [:]

    /// The inbox the panel shows.
    @ObservationIgnored var session: Session? {
        didSet {
            guard session !== oldValue else { return }
            reset()
            inboxChanged()
        }
    }
    /// A `g` waiting for its second key.
    @ObservationIgnored var pendingG = false
    /// Repositories in the order the open panel first showed them, so rows
    /// do not jump while it is open.
    @ObservationIgnored private var repositoryOrder: [RepositoryName] = []
    @ObservationIgnored private var selectedIndexHint = 0
    @ObservationIgnored private var isBatching = false

    // MARK: Layout

    /// The session's inbox changed: count the saved searches again and lay
    /// the list out.
    func inboxChanged() {
        savedCounts = Dictionary(uniqueKeysWithValues: (session?.savedSearches ?? []).map { saved in
            (saved.id, session?.items(matching: saved).count ?? 0)
        })
        relayout()
    }

    /// Lays the list out again from the session and the panel's inputs, and
    /// keeps the selection on screen.
    func relayout() {
        guard !isBatching else { return }
        items = layoutItems()
        let bundles = section == .split(.feed) && SearchQuery(searchQuery).isEmpty
        rows = ListLayout.rows(items, groupByRepository: groupByRepository, bundles: bundles, expanded: expandedBundles) { [session] item in
            item.classification.actorKind == .bot ? session?.facts(for: item.id)?.author?.login : nil
        }
        reselect()
    }

    /// Several changes, one layout.
    func batch(_ changes: () -> Void) {
        isBatching = true
        changes()
        isBatching = false
        relayout()
    }

    /// Lets repositories find their order again, as the panel opens.
    func forgetOrder() {
        repositoryOrder = []
        relayout()
    }

    /// Back to the top of Needs me with nothing selected, for a new session.
    func reset() {
        batch {
            repositoryOrder = []
            expandedBundles = []
            searchQuery = ""
            isSearching = false
            overlay = .none
            section = .split(.needsMe)
            selectedID = nil
            checked.removeAll()
        }
    }

    private func layoutItems() -> [InboxItem] {
        guard let session else { return [] }
        var items: [InboxItem]
        switch section {
        case .split(let split): items = session.snapshot.items(in: split)
        case .saved(let id): items = session.savedSearch(id).map(session.items(matching:)) ?? []
        case .myPullRequests, .cleared: items = []
        case .snoozed: items = session.snapshot.snoozed
        case .later: items = session.snapshot.later
        }
        if unreadOnly { items = items.filter(\.isUnread) }
        let query = SearchQuery(searchQuery)
        if !query.isEmpty {
            items = items.filter { query.matches($0, facts: session.facts(for: $0.id)) }
        }
        guard groupByRepository else { return items }
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

    // MARK: Reading the list

    /// The rows selection moves through, in order. My PRs reads the
    /// session's pull requests, which change with Baton's store rather than
    /// the snapshot.
    private var selectableIDs: [RowID] {
        if section == .myPullRequests { return (session?.myPullRequestNodes ?? []).map { .pullRequest($0.id) } }
        return rows.filter(\.isSelectable).map(\.id)
    }

    var selectedItem: InboxItem? {
        guard let id = selectedID?.item else { return nil }
        return items.first { $0.id == id }
    }

    /// The bundle the selection is on, if it is on one.
    var selectedBundle: ThreadBundle? {
        guard case .bundle(let kind) = selectedID else { return nil }
        return bundle(kind)
    }

    /// The pull request the selection is on in My PRs.
    var selectedPullRequestID: String? {
        if case .pullRequest(let id) = selectedID { return id }
        return nil
    }

    /// The bundle of a kind in the current layout.
    func bundle(_ kind: ThreadBundle.Kind) -> ThreadBundle? {
        for row in rows {
            if case .bundle(let bundle, _) = row, bundle.kind == kind { return bundle }
        }
        return nil
    }

    /// The bundle a thread belongs to in the current layout.
    func bundle(containing id: ItemID) -> ThreadBundle? {
        for row in rows {
            if case .bundle(let bundle, _) = row, bundle.items.contains(where: { $0.id == id }) { return bundle }
        }
        return nil
    }

    /// The rows a verb applies to: the checked ones, else the selection,
    /// which on a bundle is all of its threads.
    func targets(_ id: RowID? = nil) -> [InboxItem] {
        if id == nil, !checked.isEmpty { return items.filter { checked.contains($0.id) } }
        switch id ?? selectedID {
        case .bundle(let kind): return bundle(kind)?.items ?? []
        case .item(let item): return items.filter { $0.id == item }
        case .header, .pullRequest, nil: return []
        }
    }

    /// The tabs in order: the four splits, then saved searches.
    var tabs: [Section] { Split.allCases.map { .split($0) } + (session?.savedSearches ?? []).map { .saved($0.id) } }

    func count(_ section: Section) -> Int {
        guard let session else { return 0 }
        return switch section {
        case .split(let split): session.snapshot.count(split)
        case .saved(let id): savedCounts[id] ?? 0
        case .myPullRequests: session.myPullRequestNodes.count
        case .snoozed: session.snapshot.snoozed.count
        case .later: session.snapshot.later.count
        case .cleared: session.state.cleared.count
        }
    }

    // MARK: Moving

    func show(_ section: Section) {
        batch {
            self.section = section
            checked.removeAll()
            selectedIndexHint = 0
            selectedID = nil
        }
    }

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
        checked = checked.intersection(Set(items.map(\.id)))
    }

    func toggleBundle(_ kind: ThreadBundle.Kind) {
        selectedID = .bundle(kind)
        if expandedBundles.contains(kind) { expandedBundles.remove(kind) } else { expandedBundles.insert(kind) }
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

    // MARK: Toasts

    func toast(_ message: String) {
        let toast = Toast(message: message)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            toasts.removeAll { $0.id == toast.id }
        }
    }
}
