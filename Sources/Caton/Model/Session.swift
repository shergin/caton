import AppKit
import Baton
import CatonCore
import Observation

/// One inbox and everything that keeps it: the feed's threads, local state
/// with its action queue, the subjects' state through Baton, and where the
/// inbox is saved. A signed-in account has a session; so does the practice
/// inbox, fed by made-up threads and connected to nothing. Switching
/// accounts, or practicing, swaps the session; nothing is reset by hand.
///
/// This file holds the session's life, the feed and the projection; changes
/// to the inbox are in `Session+Changes.swift`, sending them to GitHub in
/// `Session+Dispatch.swift`, the viewer's pull requests in
/// `Session+PullRequests.swift`.
@MainActor
@Observable
final class Session {
    /// What feeds the session and where its changes go.
    enum Source {
        /// An account on GitHub.
        case github(Connection)
        /// Threads and facts held in memory, connected to nothing: the
        /// practice inbox, and tests.
        case local(facts: [String: SubjectFacts])
    }

    /// Everything that talks to GitHub for one account.
    struct Connection {
        let rest: GitHubREST
        /// Baton's environment, injected into views that own their queries.
        let graph: Baton.Environment
        let subjects: SubjectStore
        /// The image Baton reads at launch; removed at a sign-out.
        let image: Persistence?
    }

    static let grace: TimeInterval = 5
    static let recentWindow: TimeInterval = 7 * 24 * 3600

    let viewer: Viewer
    let source: Source
    /// No change reaches GitHub; for development against a real account.
    let dryRun: Bool
    /// The practice inbox: made-up threads with no pages to open.
    private(set) var isPractice = false

    // MARK: Observed state

    private(set) var snapshot = InboxSnapshot()
    /// Everything Caton knows that GitHub does not. Views read its settings,
    /// saved searches and reminders; changes go through the session.
    var state = LocalState()
    private(set) var isSyncing = false
    /// When GitHub's rate limit lets requests through again.
    private(set) var cooldownUntil: Date?
    /// The last thing that went wrong, for the status strip.
    var errorMessage: String?
    /// Writes to the viewer's pull requests waiting out the undo window.
    var pendingWrites: [String: PendingWrite] = [:]

    // MARK: Unobserved state

    @ObservationIgnored var threads: [String: NotificationThread] = [:]
    /// The user's changes, newest last, for undo.
    @ObservationIgnored var history: [Undo] = []
    /// Snoozes that ended this session, and why, so the note outlives the snooze.
    @ObservationIgnored var wokenSnoozes: [ItemID: Resurfacing] = [:]
    @ObservationIgnored private let persistence: StatePersistence?
    @ObservationIgnored private let syncsRuleClears: @MainActor () -> Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored var dispatchTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeScheduled = false
    @ObservationIgnored private(set) var hasPolled = false
    /// How long a write to a pull request waits for an undo; tests shorten it.
    @ObservationIgnored var writeGrace: Duration = .seconds(Session.grace)

    // MARK: Events

    /// After every projection, with the Needs me rows that left it.
    @ObservationIgnored var onChange: ((_ leftNeedsMe: Set<ItemID>) -> Void)?
    /// After every poll that landed; the first is the session's baseline.
    @ObservationIgnored var onPoll: ((_ isFirst: Bool) -> Void)?
    /// GitHub rejected the token.
    @ObservationIgnored var onUnauthorized: (() -> Void)?
    /// A write to a pull request landed, with what to say.
    @ObservationIgnored var onWrite: ((String) -> Void)?

    /// - Parameters:
    ///   - persisted: what an earlier launch saved for this inbox.
    ///   - persistence: where to save it; nil keeps it in memory.
    ///   - syncsRuleClears: whether rule clears are marked done on GitHub.
    init(
        viewer: Viewer,
        source: Source,
        persisted: PersistedState = PersistedState(),
        persistence: StatePersistence?,
        dryRun: Bool,
        syncsRuleClears: @escaping @MainActor () -> Bool = { false }
    ) {
        self.viewer = viewer
        self.source = source
        self.persistence = persistence
        self.dryRun = dryRun
        self.syncsRuleClears = syncsRuleClears
        state = persisted.state
        state.queue.resumeAfterLaunch()
        threads = Dictionary(persisted.threads.filter { !PracticeInbox.isPractice($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        if case .github(let connection) = source {
            connection.subjects.onChange = { [weak self] in self?.scheduleRecompute() }
        }
    }

    /// The practice inbox: made-up threads that fill every split, connected
    /// to nothing and saved nowhere.
    static func practice(now: Date = .now) -> Session {
        let entries = PracticeInbox.entries(now: now)
        let facts = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.facts.map { (entry.thread.id, $0) } })
        let session = Session(
            viewer: Viewer(login: PracticeInbox.viewerLogin, nodeID: "U_practice", scopes: []),
            source: .local(facts: facts),
            persistence: nil,
            dryRun: true
        )
        session.threads = Dictionary(uniqueKeysWithValues: entries.map { ($0.thread.id, $0.thread) })
        session.isPractice = true
        return session
    }

    // MARK: Capabilities

    var connection: Connection? {
        if case .github(let connection) = source { return connection }
        return nil
    }

    var graph: Baton.Environment? { connection?.graph }
    var subjects: SubjectStore? { connection?.subjects }

    // MARK: Life

    /// Starts the feed and the dispatcher.
    func start() {
        subjects?.sync(Array(threads.values))
        recompute()
        startDispatching()
        if connection != nil { startPolling() }
    }

    /// Stops the session's work and lets go of its subjects.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        dispatchTask?.cancel()
        dispatchTask = nil
        for write in pendingWrites.values { write.task.cancel() }
        pendingWrites.removeAll()
        subjects?.releaseAll()
    }

    /// Sends every queued action now, waits briefly, and saves: for a quit or
    /// a switch to another account.
    func drain() async {
        state.queue.expedite(now: .now)
        let deadline = Date.now.addingTimeInterval(3)
        while !state.queue.isEmpty, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        persistence?.saveNow(persisted())
    }

    // MARK: Feed

    /// Polls now. Forced, the feed is fetched even when GitHub would answer
    /// that nothing changed; otherwise the poll is a free conditional request.
    func refresh(force: Bool = true) {
        guard connection != nil else { return }
        startPolling(force: force)
    }

    private func startPolling(force: Bool = false) {
        pollTask?.cancel()
        pollTask = Task {
            var force = force
            while !Task.isCancelled {
                await pollOnce(force: force)
                force = false
                let interval = await connection?.rest.pollInterval ?? 60
                try? await Task.sleep(for: .seconds(max(interval, 60)))
            }
        }
    }

    private func pollOnce(force: Bool) async {
        guard let rest = connection?.rest else { return }
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
            subjects?.searchReviewRequests()
            errorMessage = nil
            if let cooldownUntil, cooldownUntil <= .now { self.cooldownUntil = nil }
            let isFirst = !hasPolled
            hasPolled = true
            onPoll?(isFirst)
        } catch GitHubError.unauthorized {
            errorMessage = "GitHub rejected the token. Sign in again."
            onUnauthorized?()
        } catch GitHubError.rateLimited(let until) {
            noteCooldown(until)
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
        state.prune(liveIDs: liveIDs, now: .now)
        // Read marks the feed now agrees with are no longer needed.
        state.readMarks = state.readMarks.filter { id, mark in
            guard case .thread(let threadID) = id, let thread = threads[threadID] else { return false }
            return thread.isUnread && thread.updatedAt <= mark
        }
        subjects?.sync(Array(threads.values))
        recompute()
        return true
    }

    /// Shows a rate-limit cooldown in the status strip until it ends.
    func noteCooldown(_ until: Date) {
        guard until > .now else { return }
        cooldownUntil = max(until, cooldownUntil ?? .distantPast)
        Task {
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 1))
            if let cooldownUntil, cooldownUntil <= .now { self.cooldownUntil = nil }
        }
    }

    // MARK: Projection

    /// Open pull requests that request the viewer with no notification thread.
    var reviewRequests: [NotificationThread] { subjects?.reviewRequestThreads ?? [] }

    /// Every row local state may refer to: the feed's threads and the review
    /// requests.
    private var liveIDs: Set<ItemID> {
        Set(threads.keys.map(ItemID.thread)).union(reviewRequests.map { .reviewRequest($0.id) })
    }

    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            recomputeScheduled = false
            recompute()
        }
    }

    /// Classifies the inbox again: rules clear what they clear, snoozes wake,
    /// and the snapshot every view reads is replaced.
    func recompute() {
        let now = Date.now
        let reminders = dueReminders(now: now)
        let project = { [unowned self] in
            InboxProjection.project(threads: threads.values, reviewRequests: reviewRequests, reminders: reminders, facts: { self.facts(for: $0) }, state: state, now: now)
        }
        var next = project()
        if !next.autoClears.isEmpty {
            applyRuleClears(next.autoClears, now: now)
            next = project()
        }
        for (id, why) in next.wokenSnoozes {
            state.snoozes[id] = nil
            wokenSnoozes[id] = why
        }
        for split in Split.allCases {
            guard var items = next.splits[split] else { continue }
            for index in items.indices where items[index].resurfacing == nil {
                items[index].resurfacing = wokenSnoozes[items[index].id]
            }
            next.splits[split] = items
        }
        let left = Set(snapshot.items(in: .needsMe).map(\.id)).subtracting(next.items(in: .needsMe).map(\.id))
        snapshot = next
        save()
        onChange?(left)
    }

    private func applyRuleClears(_ clears: [AutoClear], now: Date) {
        state.count(byRules: clears.count, now: now)
        let byRule = Dictionary(grouping: clears, by: \.rule)
        for (rule, clears) in byRule {
            if syncsRuleClears() {
                let batch = state.queue.enqueue(.done, clears.map { .init(item: $0.id, activity: $0.thread.updatedAt, subjectNodeID: $0.subjectNodeID) }, rule: rule, now: now, grace: Self.grace)
                state.cleared += clears.map { ClearedEntry(batch: batch, thread: $0.thread, rule: rule, at: now) }
            } else {
                // Local only until the user lets rules mark threads done on GitHub.
                let batch = UUID()
                for clear in clears {
                    state.dismissals[clear.id] = Dismissal(cause: .rule(rule), activity: clear.thread.updatedAt, at: now)
                }
                state.cleared += clears.map { ClearedEntry(batch: batch, thread: $0.thread, rule: rule, at: now) }
            }
        }
    }

    // MARK: Persistence

    func save() {
        persistence?.save { [weak self] in self?.persisted() ?? PersistedState() }
    }

    func persisted() -> PersistedState {
        PersistedState(viewer: viewer, threads: Array(threads.values), state: state, fetchedActivity: subjects?.fetchedActivity ?? [:])
    }

    // MARK: Row data

    func facts(for id: ItemID) -> SubjectFacts? {
        switch source {
        case .github(let connection): connection.subjects.facts(for: id)
        case .local(let facts): facts[id.key]
        }
    }

    func lenses(for id: ItemID) -> SubjectStore.Lenses {
        reminderLenses(id) ?? subjects?.lenses(for: id) ?? SubjectStore.Lenses()
    }

    /// "open pull request, checks failing, by dependabot (bot)", for VoiceOver.
    func spokenState(for item: InboxItem) -> String {
        guard let facts = facts(for: item.id) else { return "" }
        var parts: [String] = []
        let kind = item.thread.kind == .pullRequest ? "pull request" : "issue"
        switch facts.state {
        case .open: parts.append(facts.isDraft ? "draft \(kind)" : facts.isInMergeQueue ? "\(kind) in the merge queue" : "open \(kind)")
        case .merged: parts.append("merged \(kind)")
        case .closed: parts.append(facts.closedReason == .notPlanned ? "closed as not planned" : "closed \(kind)")
        }
        switch facts.checks {
        case .failure: parts.append("checks failing")
        case .pending: parts.append("checks running")
        case .success, nil: break
        }
        if facts.reviewDecision == .approved { parts.append("approved") }
        if facts.reviewDecision == .changesRequested { parts.append("changes requested") }
        if let author = facts.author {
            let kind = item.classification.actorKind.flatMap { $0 == .human ? nil : $0.title.lowercased() }
            parts.append("by \(author.login)" + (kind.map { " (\($0))" } ?? ""))
        }
        return parts.joined(separator: ", ")
    }
}
