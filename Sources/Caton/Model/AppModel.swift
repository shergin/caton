import AppKit
import Baton
import CatonCore
import Observation

/// The app's state and its one owner: sign-in, the feed loop, classification,
/// the action queue, alerts and what the panel shows. Views and the status
/// item read it; every change to GitHub goes through it.
///
/// This file holds sign-in, the feed and the projection; the list and its
/// verbs are in `AppModel+Inbox.swift`, sending changes to GitHub is in
/// `AppModel+Dispatch.swift`.
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

    /// What the list shows: a split, a saved search, or one of the local views.
    enum Section: Hashable {
        case split(Split)
        case saved(UUID)
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
        case peek
        case welcome
        case zero
        case why
        case tips
        case saveSearch
    }

    /// The one message the status strip shows, the most urgent first.
    enum StatusMessage: Equatable {
        case error(String)
        case cooldown(until: Date)
        case warning(String)
        case update(Updates.Release)
    }

    /// One step undo can take back.
    enum UndoEntry {
        case queued(UUID)
        case snoozed([String: Snooze?])
        case later([String: Date?])
    }

    /// What the first sync of an account found, for the welcome summary.
    struct Welcome: Equatable {
        let total: Int
        let needsMe: Int
        let cleared: [Rule: Int]
    }

    static let grace: TimeInterval = 5
    static let recentWindow: TimeInterval = 7 * 24 * 3600

    // MARK: Observed state

    private(set) var account: Account = .signedOut
    private(set) var snapshot = InboxSnapshot()
    var section: Section = .split(.needsMe)
    var selectedID: String?
    var checked: Set<String> = []
    private(set) var toasts: [Toast] = []
    var errorMessage: String?
    private(set) var signInError: String?
    private(set) var deviceSignIn: DeviceSignIn = .idle
    private(set) var isSyncing = false
    /// Bumped when classification settings change, so views reading them
    /// (they live in unobserved `state`) redraw.
    var settingsVersion = 0
    /// When GitHub's rate limit lets requests through again.
    private(set) var cooldownUntil: Date?
    var cleared: [ClearedEntry] = []
    private(set) var welcome: Welcome?
    /// Baton's environment for the signed-in account, injected into the
    /// panel so views that own their queries reach GitHub.
    private(set) var graph: Baton.Environment?
    var searchQuery = "" { didSet { reselect() } }
    var isSearching = false
    var overlay: Overlay = .none
    /// The snooze picker's mode: come back only if nothing happens.
    var snoozeOnlyIfQuiet = false
    /// A `g` waiting for its second key.
    @ObservationIgnored var pendingG = false
    var unreadOnly = false { didSet { reselect() } }
    var groupByRepository = true
    /// Feed bundles the user opened.
    var expandedBundles: Set<String> = []
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            if isPanelVisible {
                repositoryOrder = []
                refresh(force: false)
                subjects?.searchReviewRequests(force: true)
                if welcome != nil { overlay = .welcome } else { offerTips() }
            } else {
                isSearching = false
                checked.removeAll()
                if overlay != .welcome { overlay = .none }
            }
        }
    }

    /// The practice inbox is showing in place of the account's.
    private(set) var isPractice = false
    /// The detached window is open but another window has the focus.
    var isWindowInBackground = false

    let preferences: Preferences
    let banners = Banners()
    let updates: Updates
    /// Opens the settings window; set by the app delegate.
    @ObservationIgnored var openSettings: (() -> Void)?
    /// Moves the inbox into a window, and back under the menu bar icon; set
    /// by the status item.
    @ObservationIgnored var detach: (() -> Void)?
    @ObservationIgnored var attach: (() -> Void)?

    // MARK: State shared with the extensions

    @ObservationIgnored var threads: [String: NotificationThread] = [:]
    @ObservationIgnored var state = LocalState()
    @ObservationIgnored var rest: GitHubREST?
    @ObservationIgnored private(set) var subjects: SubjectStore?
    @ObservationIgnored var dispatchTask: Task<Void, Never>?
    @ObservationIgnored var undoStack: [UndoEntry] = []
    /// Snoozes that ended this session, and why, so the note outlives the snooze.
    @ObservationIgnored var wokenSnoozes: [String: Resurfacing] = [:]
    @ObservationIgnored var repositoryOrder: [String] = []
    @ObservationIgnored var selectedIndexHint = 0
    /// No change reaches GitHub; for development against a real account.
    @ObservationIgnored let dryRun = ProcessInfo.processInfo.environment["CATON_DRY_RUN"] == "1"

    // MARK: Private state

    @ObservationIgnored private let persistence: StatePersistence
    /// Opens a thread's page; the browser by default.
    @ObservationIgnored let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var batonImage: Persistence?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The account's inbox, set aside while practicing.
    @ObservationIgnored private var practiceStash: (threads: [String: NotificationThread], state: LocalState, section: Section)?
    @ObservationIgnored private var practiceFacts: [String: SubjectFacts] = [:]
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeScheduled = false
    /// Whether the session's first poll has landed; until then nothing alerts.
    @ObservationIgnored private var alertsArmed = false

    init(
        preferences: Preferences = Preferences(),
        persistence: StatePersistence = StatePersistence(),
        updates: Updates = Updates(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.preferences = preferences
        self.persistence = persistence
        self.updates = updates
        self.openURL = openURL
    }

    // MARK: Lifecycle

    func start() {
        let persisted = persistence.load()
        state = persisted.state
        state.queue.resumeAfterLaunch()
        threads = Dictionary(persisted.threads.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cleared = state.cleared
        banners.start()
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
        let flow = DeviceFlow(clientID: clientID, access: preferences.access)
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
        dispatchTask = nil
        subjects?.releaseAll()
        subjects = nil
        graph = nil
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
        welcome = nil
        overlay = .none
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
        alertsArmed = false
        let governor = RateGovernor()
        let image = Persistence(url: AppPaths.caches.appending(path: "subjects-\(viewer.login).sqlite"), version: "3")
        let environment = Baton.Environment(transport: GraphTransport(token: token, governor: governor), store: Store(persistence: image))
        environment.releaseBufferSize = 50
        let subjects = SubjectStore(environment: environment, viewerID: viewer.nodeID, fetchedActivity: fetchedActivity)
        subjects.onChange = { [weak self] in self?.scheduleRecompute() }
        rest = GitHubREST(token: token, governor: governor)
        self.subjects = subjects
        graph = environment
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
        guard rest != nil, !isPractice else { return }
        startPolling(force: force)
    }

    func startPolling(force: Bool = false) {
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
            guard !Task.isCancelled, !isPractice else { return }
            if !merge(unread: unread, recent: recent) {
                // Nothing new in the feed: subjects still refresh on their
                // schedule, and snoozes and ages still move.
                subjects?.sync(Array(threads.values))
                recompute()
            }
            if !alertsArmed {
                // The session's first poll is the baseline: what is already
                // there is seen, not announced.
                alertsArmed = true
                announce(baseline: true)
                prepareWelcome()
            }
            subjects?.searchReviewRequests()
            offerDigest()
            errorMessage = nil
            if let cooldownUntil, cooldownUntil <= .now { self.cooldownUntil = nil }
        } catch GitHubError.unauthorized {
            errorMessage = "GitHub rejected the token. Sign in again."
            signOut()
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
        let live = allThreads
        state.prune(liveThreadIDs: Set(live.map(\.id)), now: .now)
        // Read marks the feed now agrees with are no longer needed.
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        state.readMarks = state.readMarks.filter { id, mark in byID[id].map { $0.isUnread && $0.updatedAt <= mark } ?? false }
        subjects?.sync(Array(threads.values))
        recompute()
        return true
    }

    // MARK: Projection

    /// The feed's threads plus review requests that have no notification.
    var allThreads: [NotificationThread] {
        let feed = Array(threads.values)
        if isPractice { return feed }
        guard let requests = subjects?.reviewRequestThreads, !requests.isEmpty else { return feed }
        let known = Set(feed.filter { $0.kind == .pullRequest }.map(\.reference))
        return feed + requests.filter { !known.contains($0.reference) }
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

    func recompute() {
        let now = Date.now
        var next = InboxProjection.project(threads: allThreads, facts: { [unowned self] in facts(for: $0) }, state: state, now: now)
        if !next.autoClears.isEmpty {
            applyRuleClears(next.autoClears, now: now)
            next = InboxProjection.project(threads: allThreads, facts: { [unowned self] in facts(for: $0) }, state: state, now: now)
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
        cleared = state.cleared
        reselect()
        if alertsArmed { announce(baseline: false) }
        if !left.isEmpty { banners.withdraw(Array(left)) }
        save()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CATON_DUMP"] == "1" { dump() }
        #endif
    }

    private func applyRuleClears(_ clears: [AutoClear], now: Date) {
        state.count(byRules: clears.count, now: now)
        let byRule = Dictionary(grouping: clears, by: \.rule)
        for (rule, clears) in byRule {
            if preferences.syncRuleClears {
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

    // MARK: Alerts

    private func announce(baseline: Bool) {
        guard !isPractice else { return }
        let decision = AlertPolicy.decide(
            needsMe: snapshot.items(in: .needsMe),
            alerted: state.alerted,
            isPanelVisible: isPanelVisible && !isWindowInBackground,
            quietHours: preferences.quietHours,
            isEnabled: preferences.alertsEnabled,
            isBaseline: baseline,
            cap: preferences.alertCap,
            now: .now
        )
        state.alerted.merge(decision.alerted) { _, new in new }
        banners.show(decision)
    }

    /// The morning digest, once on a working day, if the user turned it on.
    private func offerDigest(now: Date = .now) {
        guard preferences.digestEnabled, DigestPolicy.isDue(lastShown: preferences.lastDigest, quietHours: preferences.quietHours, now: now) else { return }
        // Overnight: since yesterday's digest, at most a day back.
        let since = preferences.lastDigest.map { max($0, now.addingTimeInterval(-24 * 3600)) } ?? now.addingTimeInterval(-16 * 3600)
        preferences.lastDigest = now
        let overnight = state.cleared.filter { $0.rule != nil && $0.at >= since }.count
        guard let message = DigestPolicy.message(needsMe: snapshot.count(.needsMe), clearedOvernight: overnight) else { return }
        banners.showDigest(message)
    }

    /// Shows the panel's welcome summary once per account, after its first sync.
    private func prepareWelcome() {
        guard case .signedIn(let viewer) = account, !preferences.welcomedAccounts.contains(viewer.login) else { return }
        welcome = Welcome(
            total: allThreads.count,
            needsMe: snapshot.count(.needsMe),
            cleared: Dictionary(grouping: state.cleared.compactMap(\.rule), by: { $0 }).mapValues(\.count)
        )
        if isPanelVisible { overlay = .welcome }
    }

    func finishWelcome(syncRuleClears: Bool) {
        preferences.syncRuleClears = syncRuleClears
        if case .signedIn(let viewer) = account { preferences.welcomedAccounts.insert(viewer.login) }
        welcome = nil
        overlay = .none
        offerTips()
        if syncRuleClears {
            // Rule clears so far stayed local; now they reach GitHub too, but
            // only where the clear still covers the thread's latest activity.
            let targets = state.dismissals.compactMap { id, dismissal -> ActionQueue.Target? in
                guard case .rule = dismissal.cause, let thread = threads[id], thread.updatedAt <= dismissal.activity else { return nil }
                return ActionQueue.Target(threadID: id, activity: dismissal.activity)
            }
            if !targets.isEmpty {
                state.queue.enqueue(.done, targets, now: .now, grace: Self.grace)
                wakeDispatcher()
            }
        }
    }

    /// "3 need you · 12 team · 8 following · 41 feed", for the menu bar's
    /// tooltip and VoiceOver.
    var countsSummary: String {
        let needsMe = snapshot.count(.needsMe)
        return [
            needsMe == 0 ? "nothing needs you" : "\(needsMe) need\(needsMe == 1 ? "s" : "") you",
            "\(snapshot.count(.team)) team",
            "\(snapshot.count(.following)) following",
            "\(snapshot.count(.feed)) feed",
        ].joined(separator: " · ")
    }

    /// Checks for a newer release and says what it found.
    func checkForUpdates() {
        Task {
            await updates.check(userInitiated: true)
            let alert = NSAlert()
            alert.messageText = updates.status ?? "Caton \(updates.currentVersion)"
            if let release = updates.available {
                alert.informativeText = "You have \(updates.currentVersion)."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn { openURL(release.url) }
            } else {
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    /// Shows the three-key tip once, on a signed-in panel with nothing else over it.
    func offerTips() {
        guard !preferences.tipsShown, case .signedIn = account, overlay == .none else { return }
        overlay = .tips
    }

    func dismissTips() {
        preferences.tipsShown = true
        if overlay == .tips { overlay = .none }
    }

    /// Shows a thread a banner named.
    func reveal(_ threadID: String?) {
        show(.split(.needsMe))
        if let threadID, visibleItems.contains(where: { $0.id == threadID }) { select(threadID) }
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

    /// Shows a rate-limit cooldown in the status strip until it ends.
    func noteCooldown(_ until: Date) {
        guard until > .now else { return }
        cooldownUntil = max(until, cooldownUntil ?? .distantPast)
        Task {
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 1))
            if let cooldownUntil, cooldownUntil <= .now { self.cooldownUntil = nil }
        }
    }

    /// What the status strip shows: an error, else a cooldown, else a
    /// warning, else an available update.
    var statusMessage: StatusMessage? {
        if let errorMessage { return .error(errorMessage) }
        if let cooldownUntil, cooldownUntil > .now { return .cooldown(until: cooldownUntil) }
        if let warning { return .warning(warning) }
        if let release = updates.available { return .update(release) }
        return nil
    }

    private var warning: String? {
        if let status = preferences.hotKeyStatus { return status }
        let retrying = state.queue.actions.filter { $0.attempts > 0 }.count
        if retrying > 0 { return retrying == 1 ? "1 change is waiting to reach GitHub." : "\(retrying) changes are waiting to reach GitHub." }
        return nil
    }

    // MARK: Persistence

    func save() {
        // Practice never touches the account's saved state.
        guard !isPractice else { return }
        persistence.save { [weak self] in self?.persisted() ?? PersistedState() }
    }

    private func persisted() -> PersistedState {
        var viewer: Viewer?
        if case .signedIn(let signedIn) = account { viewer = signedIn }
        return PersistedState(viewer: viewer, threads: Array(threads.values), state: state, fetchedActivity: subjects?.fetchedActivity ?? [:])
    }

    // MARK: Row data

    func lenses(for id: String) -> SubjectStore.Lenses {
        isPractice ? SubjectStore.Lenses() : subjects?.lenses(for: id) ?? SubjectStore.Lenses()
    }

    func facts(for thread: NotificationThread) -> SubjectFacts? {
        isPractice ? practiceFacts[thread.id] : subjects?.facts(for: thread)
    }

    // MARK: Practice

    /// Swaps in a made-up inbox to learn the keys on. Polling pauses, nothing
    /// is sent to GitHub or saved, and the account's inbox comes back as it
    /// was on exit.
    func enterPractice() {
        guard !isPractice else { return }
        practiceStash = (threads, state, section)
        pollTask?.cancel()
        dispatchTask?.cancel()
        dispatchTask = nil
        let entries = PracticeInbox.entries(now: .now)
        isPractice = true
        threads = Dictionary(uniqueKeysWithValues: entries.map { ($0.thread.id, $0.thread) })
        practiceFacts = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.facts.map { (entry.thread.id, $0) } })
        state = LocalState()
        undoStack.removeAll()
        wokenSnoozes.removeAll()
        repositoryOrder = []
        expandedBundles = []
        searchQuery = ""
        overlay = .none
        show(.split(.needsMe))
        recompute()
        startDispatching()
        toast("Practice inbox: try e, h, u, x, z and ⌘K")
    }

    func exitPractice() {
        guard isPractice, let stash = practiceStash else { return }
        dispatchTask?.cancel()
        dispatchTask = nil
        isPractice = false
        practiceStash = nil
        practiceFacts = [:]
        threads = stash.threads
        state = stash.state
        // An action caught in flight when practice began goes again.
        state.queue.resumeAfterLaunch()
        undoStack.removeAll()
        wokenSnoozes.removeAll()
        repositoryOrder = []
        expandedBundles = []
        overlay = .none
        show(stash.section)
        recompute()
        if rest != nil {
            startPolling()
            startDispatching()
        }
    }

    /// "open pull request, checks failing, by dependabot (bot)", for VoiceOver.
    func spokenState(for item: InboxItem) -> String {
        guard let facts = facts(for: item.thread) else { return "" }
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

    // MARK: Debugging

    #if DEBUG
    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Prints the inbox as classified, for checking rules against a real account.
    private func dump() {
        let counts = Split.allCases.map { "\($0.title) \(snapshot.count($0))" }.joined(separator: " · ")
        let enriched = threads.values.filter { subjects?.facts(for: $0) != nil }.count
        let requests = subjects?.reviewRequestThreads.count ?? 0
        log("[caton] threads \(threads.count), enriched \(enriched), review requests \(requests), cleared \(state.cleared.count), snoozed \(snapshot.snoozed.count) | \(counts)")
        for split in Split.allCases {
            for item in snapshot.items(in: split).prefix(4) {
                let rule = item.classification.routedBy.map { " routed:\($0.rawValue)" } ?? ""
                let actor = item.classification.actorKind.map { " actor:\($0.rawValue)" } ?? ""
                log("[caton]   \(split.title): \(item.thread.reference) [\(item.thread.reason.rawValue) -> \(item.classification.badge.title)]\(rule)\(actor)\(item.isUnread ? " unread" : "")")
            }
        }
    }
    #endif
}
