import AppKit
import Baton
import CatonCore
import Observation

/// The app's state and its one owner: sign-in, the feed loop, classification,
/// the action queue and what the panel shows. Views and the status item read
/// it; every change to GitHub goes through it.
@MainActor
@Observable
final class AppModel {
    enum Account: Equatable {
        case signedOut
        case connecting
        case signedIn(Viewer)
    }

    enum DeviceSignIn: Equatable {
        case idle
        case waiting(userCode: String, url: URL)
    }

    /// What the list shows: a split, or one of the local views.
    enum Section: Hashable {
        case split(Split)
        case snoozed
        case later
        case cleared
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    /// A transient layer over the list that takes the keyboard.
    enum Overlay: Equatable {
        case none
        case snooze
        case commands
        case help
    }

    /// One step undo can take back.
    private enum UndoEntry {
        case queued(UUID)
        case snoozed([String: Snooze?])
        case later([String: Date?])
    }

    static let grace: TimeInterval = 5
    static let recentWindow: TimeInterval = 7 * 24 * 3600

    // MARK: Observed state

    private(set) var account: Account = .signedOut
    private(set) var snapshot = InboxSnapshot()
    private(set) var section: Section = .split(.needsMe)
    private(set) var selectedID: String?
    private(set) var checked: Set<String> = []
    private(set) var toasts: [Toast] = []
    private(set) var errorMessage: String?
    private(set) var signInError: String?
    private(set) var deviceSignIn: DeviceSignIn = .idle
    private(set) var isSyncing = false
    private(set) var cleared: [ClearedEntry] = []
    var searchQuery = "" { didSet { reselect() } }
    var isSearching = false
    var overlay: Overlay = .none
    /// A `g` waiting for its second key.
    @ObservationIgnored var pendingG = false
    var unreadOnly = false { didSet { reselect() } }
    var groupByRepository = true
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            if isPanelVisible {
                repositoryOrder = []
                refresh(force: false)
            } else {
                isSearching = false
                checked.removeAll()
            }
        }
    }
    /// Settings that are not classification: kept in user defaults.
    var syncRuleClears: Bool = UserDefaults.standard.bool(forKey: "syncRuleClears") {
        didSet { UserDefaults.standard.set(syncRuleClears, forKey: "syncRuleClears") }
    }

    // MARK: Private state

    @ObservationIgnored private var threads: [String: NotificationThread] = [:]
    @ObservationIgnored private var state = LocalState()
    @ObservationIgnored private var rest: GitHubREST?
    @ObservationIgnored private(set) var subjects: SubjectStore?
    @ObservationIgnored private var persistence = StatePersistence()
    @ObservationIgnored private var batonImage: Persistence?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var dispatchTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var undoStack: [UndoEntry] = []
    @ObservationIgnored private var wokenSnoozes: Set<String> = []
    @ObservationIgnored private var repositoryOrder: [String] = []
    @ObservationIgnored private var selectedIndexHint = 0
    @ObservationIgnored private var recomputeScheduled = false
    /// No change reaches GitHub; for development against a real account.
    @ObservationIgnored let dryRun = ProcessInfo.processInfo.environment["CATON_DRY_RUN"] == "1"

    // MARK: Lifecycle

    func start() {
        let persisted = persistence.load()
        state = persisted.state
        state.queue.resumeAfterLaunch()
        threads = Dictionary(persisted.threads.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cleared = state.cleared
        guard let token = TokenStore.load() else { return }
        connect(token: token, expected: persisted.viewer, fetchedActivity: persisted.fetchedActivity)
    }

    /// Sends every queued action now and waits briefly, for a quit.
    func drain() async {
        state.queue.expedite(now: .now)
        let deadline = Date.now.addingTimeInterval(3)
        while !state.queue.isEmpty, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        persistence.saveNow(persisted())
    }

    // MARK: Sign-in

    func signIn(token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        connect(token: token, expected: nil, fetchedActivity: [:], save: true)
    }

    func signInWithGitHubCLI() {
        signInError = nil
        signInTask = Task {
            do {
                signIn(token: try await GitHubCLI.token())
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    func signInWithDeviceFlow() {
        guard let clientID = DeviceFlow.clientID else {
            signInError = "Device sign-in needs an OAuth App client id (CatonGitHubClientID)."
            return
        }
        signInError = nil
        let flow = DeviceFlow(clientID: clientID)
        signInTask = Task {
            do {
                let code = try await flow.requestCode()
                deviceSignIn = .waiting(userCode: code.userCode, url: code.verificationURL)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURL)
                let token = try await flow.waitForToken(code)
                deviceSignIn = .idle
                signIn(token: token)
            } catch is CancellationError {
                deviceSignIn = .idle
            } catch {
                deviceSignIn = .idle
                signInError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        deviceSignIn = .idle
    }

    func signOut() {
        pollTask?.cancel()
        dispatchTask?.cancel()
        subjects?.releaseAll()
        subjects = nil
        rest = nil
        batonImage?.removeAll()
        batonImage = nil
        TokenStore.delete()
        persistence.remove()
        threads.removeAll()
        state = LocalState()
        cleared = []
        undoStack.removeAll()
        snapshot = InboxSnapshot()
        account = .signedOut
        errorMessage = nil
    }

    /// Signs in with a token. At launch, with the account known from last
    /// time, the cached inbox renders at once and the token is checked behind
    /// it; a new sign-in waits for the check.
    private func connect(token: String, expected: Viewer?, fetchedActivity: [String: Date], save: Bool = false) {
        signInError = nil
        if let expected, !save {
            activate(token: token, viewer: expected, fetchedActivity: fetchedActivity)
        } else {
            account = .connecting
        }
        Task {
            do {
                let viewer = try await GitHubREST(token: token).viewer()
                if save { try TokenStore.save(token) }
                if case .signedIn(let current) = account, current.login == viewer.login { return }
                if let expected, expected.login != viewer.login {
                    // Another account: nothing local carries over.
                    threads.removeAll()
                    state = LocalState()
                    activate(token: token, viewer: viewer, fetchedActivity: [:])
                } else {
                    activate(token: token, viewer: viewer, fetchedActivity: fetchedActivity)
                }
            } catch GitHubError.unauthorized {
                if save {
                    signInError = GitHubError.unauthorized.localizedDescription
                    account = .signedOut
                } else {
                    errorMessage = "GitHub rejected the saved token. Sign in again."
                    signOut()
                }
            } catch {
                if save {
                    signInError = error.localizedDescription
                    account = .signedOut
                } else {
                    // Offline at launch: the cache stays up and polling keeps trying.
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func activate(token: String, viewer: Viewer, fetchedActivity: [String: Date]) {
        pollTask?.cancel()
        dispatchTask?.cancel()
        subjects?.releaseAll()
        let governor = RateGovernor()
        let image = Persistence(url: AppPaths.caches.appending(path: "subjects-\(viewer.login).sqlite"), version: "1")
        let environment = Baton.Environment(transport: GraphTransport(token: token, governor: governor), store: Store(persistence: image))
        environment.releaseBufferSize = 50
        let subjects = SubjectStore(environment: environment, viewerID: viewer.nodeID, fetchedActivity: fetchedActivity)
        subjects.onChange = { [weak self] in self?.scheduleRecompute() }
        rest = GitHubREST(token: token, governor: governor)
        self.subjects = subjects
        batonImage = image
        account = .signedIn(viewer)
        subjects.sync(Array(threads.values))
        recompute()
        startPolling()
        startDispatching()
    }

    // MARK: Feed

    /// Polls now. Forced, the feed is fetched even when GitHub would answer
    /// that nothing changed; otherwise the poll is a free conditional request.
    func refresh(force: Bool = true) {
        guard rest != nil else { return }
        startPolling(force: force)
    }

    private func startPolling(force: Bool = false) {
        pollTask?.cancel()
        pollTask = Task {
            var force = force
            while !Task.isCancelled {
                await pollOnce(force: force)
                force = false
                let interval = await rest?.pollInterval ?? 60
                try? await Task.sleep(for: .seconds(max(interval, 60)))
            }
        }
    }

    private func pollOnce(force: Bool) async {
        guard let rest else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let unread = try await rest.pollUnread(force: force)
            let recent = try await rest.pollRecent(since: .now.addingTimeInterval(-Self.recentWindow), force: force)
            guard !Task.isCancelled else { return }
            if !merge(unread: unread, recent: recent) {
                // Nothing new in the feed: subjects still refresh on their
                // schedule, and snoozes and ages still move.
                subjects?.sync(Array(threads.values))
                recompute()
            }
            errorMessage = nil
        } catch GitHubError.unauthorized {
            errorMessage = "GitHub rejected the token. Sign in again."
            signOut()
        } catch is CancellationError {
            return
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Folds a poll into the threads; returns whether anything changed.
    @discardableResult
    private func merge(unread: FeedPoll, recent: FeedPoll) -> Bool {
        var changed = false
        if case .changed(let unreadThreads) = unread {
            let unreadIDs = Set(unreadThreads.map(\.id))
            // Unread here but not in the feed: read elsewhere, or done elsewhere.
            for (id, thread) in threads where thread.isUnread && !unreadIDs.contains(id) {
                threads[id]?.isUnread = false
            }
            for thread in unreadThreads { threads[thread.id] = thread }
            changed = true
        }
        if case .changed(let recentThreads) = recent {
            for thread in recentThreads {
                // The unread feed is authoritative for unread state when both have the thread.
                if let existing = threads[thread.id], existing.isUnread, !thread.isUnread, existing.updatedAt > thread.updatedAt { continue }
                threads[thread.id] = thread
            }
            changed = true
        }
        guard changed else { return false }
        // Forget read threads nobody will see again.
        let horizon = Date.now.addingTimeInterval(-4 * Self.recentWindow)
        threads = threads.filter { $0.value.isUnread || $0.value.updatedAt > horizon }
        state.prune(liveThreadIDs: Set(threads.keys), now: .now)
        // Read marks the feed now agrees with are no longer needed.
        state.readMarks = state.readMarks.filter { id, mark in threads[id].map { $0.isUnread && $0.updatedAt <= mark } ?? false }
        subjects?.sync(Array(threads.values))
        recompute()
        return true
    }

    // MARK: Projection

    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            recomputeScheduled = false
            recompute()
        }
    }

    private func recompute() {
        let now = Date.now
        var next = InboxProjection.project(threads: threads.values, facts: { [subjects] in subjects?.facts(for: $0) }, state: state, now: now)
        if !next.autoClears.isEmpty {
            applyRuleClears(next.autoClears, now: now)
            next = InboxProjection.project(threads: threads.values, facts: { [subjects] in subjects?.facts(for: $0) }, state: state, now: now)
        }
        for id in next.wokenSnoozes {
            state.snoozes[id] = nil
            wokenSnoozes.insert(id)
        }
        for split in Split.allCases {
            guard var items = next.splits[split] else { continue }
            for index in items.indices where items[index].resurfacing == nil && wokenSnoozes.contains(items[index].id) {
                items[index].resurfacing = .snoozeEnded
            }
            next.splits[split] = items
        }
        snapshot = next
        cleared = state.cleared
        reselect()
        save()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CATON_DUMP"] == "1" { dump() }
        #endif
    }

    #if DEBUG
    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Prints the inbox as classified, for checking rules against a real account.
    private func dump() {
        let counts = Split.allCases.map { "\($0.title) \(snapshot.count($0))" }.joined(separator: " · ")
        let enriched = threads.values.filter { subjects?.facts(for: $0) != nil }.count
        log("[caton] threads \(threads.count), enriched \(enriched), cleared \(state.cleared.count), snoozed \(snapshot.snoozed.count) | \(counts)")
        for split in Split.allCases {
            for item in snapshot.items(in: split).prefix(4) {
                let rule = item.classification.routedBy.map { " routed:\($0.rawValue)" } ?? ""
                let actor = item.classification.actorKind.map { " actor:\($0.rawValue)" } ?? ""
                log("[caton]   \(split.title): \(item.thread.reference) [\(item.thread.reason.rawValue) -> \(item.classification.badge.title)]\(rule)\(actor)\(item.isUnread ? " unread" : "")")
            }
        }
    }
    #endif

    private func applyRuleClears(_ clears: [AutoClear], now: Date) {
        let byRule = Dictionary(grouping: clears, by: \.rule)
        for (rule, clears) in byRule {
            if syncRuleClears {
                let batch = state.queue.enqueue(.done, clears.map { .init(threadID: $0.thread.id, activity: $0.thread.updatedAt, subjectNodeID: $0.subjectNodeID) }, rule: rule, now: now, grace: Self.grace)
                state.cleared += clears.map { ClearedEntry(batch: batch, thread: $0.thread, rule: rule, at: now) }
            } else {
                // Local only until the user lets rules mark threads done on GitHub.
                let batch = UUID()
                for clear in clears {
                    state.dismissals[clear.thread.id] = Dismissal(cause: .rule(rule), activity: clear.thread.updatedAt, at: now)
                }
                state.cleared += clears.map { ClearedEntry(batch: batch, thread: $0.thread, rule: rule, at: now) }
            }
        }
    }

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
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = items.filter { $0.thread.title.localizedStandardContains(query) || $0.thread.reference.localizedStandardContains(query) }
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
    private func reselect() {
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
    private func targets(_ id: String? = nil) -> [InboxItem] {
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
        let batch = state.queue.enqueue(verb, items.map { .init(threadID: $0.id, activity: $0.thread.updatedAt, subjectNodeID: subjects?.facts(for: $0.thread)?.nodeID) }, now: .now, grace: Self.grace)
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

    // MARK: Dispatch

    private func startDispatching() {
        dispatchTask?.cancel()
        dispatchTask = Task {
            while !Task.isCancelled {
                if let action = state.queue.takeDue(now: .now) {
                    await execute(action)
                    // GitHub asks for a second between mutations sent in bulk.
                    try? await Task.sleep(for: action.verb == .markRead ? .milliseconds(250) : .seconds(1))
                } else {
                    let wait = state.queue.nextDueDate.map { max(0.1, $0.timeIntervalSinceNow) } ?? 1
                    try? await Task.sleep(for: .seconds(min(wait, 1)))
                }
            }
        }
    }

    private func wakeDispatcher() {
        if dispatchTask == nil, rest != nil { startDispatching() }
    }

    private func execute(_ action: QueuedAction) async {
        guard let rest else { return }
        do {
            if !dryRun {
                switch action.verb {
                case .markRead:
                    try await rest.markRead(threadID: action.threadID)
                case .done:
                    try await rest.markDone(threadID: action.threadID)
                case .unsubscribe:
                    try await rest.unsubscribe(threadID: action.threadID)
                    try await rest.markDone(threadID: action.threadID)
                case .ignore:
                    try await rest.ignore(threadID: action.threadID)
                    try await rest.markDone(threadID: action.threadID)
                }
            }
            state.queue.complete(action.id)
            switch action.verb {
            case .markRead: break
            case .done: state.dismissals[action.threadID] = Dismissal(cause: action.rule.map { .rule($0) } ?? .done, activity: action.activity, at: .now)
            case .unsubscribe: state.dismissals[action.threadID] = Dismissal(cause: .unsubscribe, activity: action.activity, at: .now)
            case .ignore: state.dismissals[action.threadID] = Dismissal(cause: .ignore, activity: action.activity, at: .now)
            }
            save()
        } catch GitHubError.unauthorized {
            _ = state.queue.fail(action.id, retryable: true, now: .now)
            errorMessage = "GitHub rejected the token. Sign in again."
        } catch {
            let retryable = (error as? GitHubError)?.isRetryable ?? true
            if let dropped = state.queue.fail(action.id, retryable: retryable, now: .now) {
                state.readMarks[dropped.threadID] = nil
                let reference = threads[dropped.threadID]?.reference ?? "a thread"
                errorMessage = "Couldn't \(dropped.verb.failureTitle) \(reference): \(error.localizedDescription)"
                recompute()
            }
        }
    }

    // MARK: Feedback

    func toast(_ message: String) {
        let toast = Toast(message: message)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            toasts.removeAll { $0.id == toast.id }
        }
    }

    func dismissError() { errorMessage = nil }

    // MARK: Persistence

    private func save() {
        persistence.save { [weak self] in self?.persisted() ?? PersistedState() }
    }

    private func persisted() -> PersistedState {
        var viewer: Viewer?
        if case .signedIn(let signedIn) = account { viewer = signedIn }
        return PersistedState(viewer: viewer, threads: Array(threads.values), state: state, fetchedActivity: subjects?.fetchedActivity ?? [:])
    }

    // MARK: Row data

    func pullRequest(for id: String) -> PullRequestSubjectQuery.Data.Repository.PullRequest? { subjects?.pullRequest(for: id) }
    func issue(for id: String) -> IssueSubjectQuery.Data.Repository.Issue? { subjects?.issue(for: id) }
}

extension Verb {
    var failureTitle: String {
        switch self {
        case .markRead: "mark read"
        case .done: "mark done"
        case .unsubscribe: "unsubscribe from"
        case .ignore: "ignore"
        }
    }
}
