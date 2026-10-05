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
        case myPullRequests
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
        case snoozed([ItemID: Snooze?])
        case later([ItemID: Date?])
        case followUps([String: FollowUp?])
        /// A write to a pull request still in its undo window.
        case pullRequestWrite(String)
    }

    /// What the snooze picker will act on.
    enum SnoozeTarget: Equatable {
        /// The selected or checked threads.
        case threads
        /// A reminder on one of the viewer's pull requests, by node id.
        case pullRequest(String)
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
    private(set) var snapshot = InboxSnapshot() { didSet { snapshotVersion &+= 1 } }
    var section: Section = .split(.needsMe)
    var selectedID: RowID?
    var checked: Set<ItemID> = []
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
    var snoozeTarget: SnoozeTarget = .threads
    /// Writes to the viewer's pull requests waiting out the undo window.
    var pendingWrites: [String: PendingWrite] = [:]
    /// How long a write to a pull request waits for an undo; tests shorten it.
    @ObservationIgnored var writeGrace: Duration = .seconds(AppModel.grace)
    /// A `g` waiting for its second key.
    @ObservationIgnored var pendingG = false
    var unreadOnly = false { didSet { reselect() } }
    var groupByRepository = true
    /// Feed bundles the user opened.
    var expandedBundles: Set<ThreadBundle.Kind> = []
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

    /// The sign-in screen is up for another account; the others stay signed in.
    private(set) var isAddingAccount = false
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
    /// Brings the panel (or the detached window) up; set by the status item.
    @ObservationIgnored var revealPanel: (() -> Void)?
    @ObservationIgnored var attach: (() -> Void)?

    // MARK: State shared with the extensions

    @ObservationIgnored var threads: [String: NotificationThread] = [:]
    @ObservationIgnored var state = LocalState()
    @ObservationIgnored var rest: GitHubREST?
    @ObservationIgnored private(set) var subjects: SubjectStore?
    @ObservationIgnored var dispatchTask: Task<Void, Never>?
    @ObservationIgnored var undoStack: [UndoEntry] = []
    /// Snoozes that ended this session, and why, so the note outlives the snooze.
    @ObservationIgnored var wokenSnoozes: [ItemID: Resurfacing] = [:]
    /// Repositories in the order the open panel first showed them.
    @ObservationIgnored var repositoryOrder: [RepositoryName] = [] {
        didSet { if repositoryOrder.isEmpty { listCache = nil } }
    }
    /// Counts snapshot changes, so the list's cache knows when it is stale.
    @ObservationIgnored var snapshotVersion = 0
    /// The current section's list, laid out once per change to what it
    /// depends on; a keystroke reads it many times.
    @ObservationIgnored var listCache: ListCache?
    @ObservationIgnored var savedCountCache: (key: [Int], counts: [UUID: Int])?
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
        banners.start()
        adoptSingleAccount()
        if let key = preferences.activeAccount ?? preferences.accounts.first?.key {
            open(account: key)
        } else if let token = TokenStore.environmentToken {
            connect(token: token, host: .dotCom, expected: nil, fetchedActivity: [:])
        }
    }

    /// Gives the token and inbox of a version with a single account to that
    /// account by name.
    private func adoptSingleAccount() {
        guard preferences.accounts.isEmpty, FileManager.default.fileExists(atPath: persistence.legacyURL.path) else { return }
        guard let viewer = persistence.load().viewer else { return }
        if let token = TokenStore.loadLegacy() {
            try? TokenStore.save(token, account: viewer.key)
            TokenStore.deleteLegacy()
        }
        persistence.adoptLegacy(as: viewer.key)
        preferences.accounts = [viewer]
        preferences.activeAccount = viewer.key
    }

    /// Loads an account's saved inbox, shows it at once, and connects.
    private func open(account key: String) {
        persistence.use(account: key)
        let persisted = persistence.load()
        state = persisted.state
        state.queue.resumeAfterLaunch()
        threads = Dictionary(persisted.threads.filter { !PracticeInbox.isPractice($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cleared = state.cleared
        let record = preferences.accounts.first { $0.key == key } ?? persisted.viewer
        guard let token = TokenStore.environmentToken ?? TokenStore.load(account: key) else {
            signInError = "Sign in to \(key) again."
            account = .signedOut
            return
        }
        connect(token: token, host: record?.host ?? .dotCom, expected: record, fetchedActivity: persisted.fetchedActivity)
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

    // MARK: Accounts

    /// The active account's key, `github.com/octocat`.
    var activeAccountKey: String? {
        if case .signedIn(let viewer) = account { return viewer.key }
        return nil
    }

    /// Shows another signed-in account's inbox. The current one's queued
    /// changes get a moment to reach GitHub, and its inbox is saved.
    func switchAccount(to key: String) {
        guard key != activeAccountKey, !isPractice, preferences.accounts.contains(where: { $0.key == key }) else { return }
        Task {
            await setAside()
            preferences.activeAccount = key
            open(account: key)
            toast("Switched to \(key)")
        }
    }

    /// The next account in the list, for the command menu.
    func switchToNextAccount() {
        let keys = preferences.accounts.map(\.key)
        guard keys.count > 1 else {
            toast("Only one account is signed in")
            return
        }
        let index = activeAccountKey.flatMap { keys.firstIndex(of: $0) } ?? -1
        switchAccount(to: keys[(index + 1) % keys.count])
    }

    /// Shows the sign-in screen for another account, keeping this one.
    func addAccount() {
        Task {
            await setAside()
            isAddingAccount = true
            account = .signedOut
            revealPanel?()
        }
    }

    /// Goes back to the account that was showing before "Add account".
    func cancelAddingAccount() {
        cancelSignIn()
        isAddingAccount = false
        if let key = preferences.activeAccount { open(account: key) }
    }

    /// Puts the current account away: changes waiting to reach GitHub get a
    /// moment, the inbox is saved, and its tasks stop.
    private func setAside() async {
        if case .signedIn = account { await drain() }
        stopAccountTasks()
        clearInbox()
    }

    private func stopAccountTasks() {
        pollTask?.cancel()
        dispatchTask?.cancel()
        dispatchTask = nil
        subjects?.releaseAll()
        subjects = nil
        graph = nil
        rest = nil
        batonImage = nil
        alertsArmed = false
    }

    private func clearInbox() {
        threads.removeAll()
        state = LocalState()
        cleared = []
        undoStack.removeAll()
        wokenSnoozes.removeAll()
        repositoryOrder = []
        expandedBundles = []
        snapshot = InboxSnapshot()
        welcome = nil
        overlay = .none
        section = .split(.needsMe)
        selectedID = nil
        checked.removeAll()
        errorMessage = nil
        cooldownUntil = nil
    }

    // MARK: Sign-in

    func signIn(token: String, host: GitHubHost = .dotCom) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        connect(token: token, host: host, expected: nil, fetchedActivity: [:], save: true)
    }

    func signInWithGitHubCLI(host: GitHubHost = .dotCom) {
        signInError = nil
        signInTask = Task {
            do {
                signIn(token: try await GitHubCLI.token(host: host), host: host)
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

    /// Signs the active account out: its token, its saved inbox and its
    /// cached subjects go. Another signed-in account, if any, takes its place.
    func signOut() {
        if isPractice { exitPractice() }
        let key = activeAccountKey ?? preferences.activeAccount
        let image = batonImage
        stopAccountTasks()
        image?.removeAll()
        if let key {
            TokenStore.delete(account: key)
            persistence.use(account: key)
            preferences.accounts.removeAll { $0.key == key }
        }
        persistence.remove()
        clearInbox()
        account = .signedOut
        isAddingAccount = false
        if let next = preferences.accounts.first {
            preferences.activeAccount = next.key
            open(account: next.key)
        } else {
            preferences.activeAccount = nil
        }
    }

    /// Signs in with a token. At launch, with the account known from last
    /// time, the cached inbox renders at once and the token is checked behind
    /// it; a new sign-in waits for the check.
    private func connect(token: String, host: GitHubHost, expected: Viewer?, fetchedActivity: [String: Date], save: Bool = false) {
        signInError = nil
        if let expected, !save {
            activate(token: token, viewer: expected, fetchedActivity: fetchedActivity)
        } else {
            account = .connecting
        }
        Task {
            do {
                let viewer = try await GitHubREST(token: token, host: host).viewer()
                if save { try TokenStore.save(token, account: viewer.key) }
                if case .signedIn(let current) = account, current.key == viewer.key {
                    remember(viewer)
                    return
                }
                // A new sign-in, or a token that turned out to be another
                // account's: show that account's own saved inbox, if any.
                stopAccountTasks()
                persistence.use(account: viewer.key)
                let persisted = persistence.load()
                state = persisted.state
                state.queue.resumeAfterLaunch()
                threads = Dictionary(persisted.threads.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                cleared = state.cleared
                activate(token: token, viewer: viewer, fetchedActivity: persisted.fetchedActivity)
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

    /// Records a signed-in account and makes it the active one.
    private func remember(_ viewer: Viewer) {
        if let index = preferences.accounts.firstIndex(where: { $0.key == viewer.key }) {
            if preferences.accounts[index] != viewer { preferences.accounts[index] = viewer }
        } else {
            preferences.accounts.append(viewer)
        }
        if preferences.activeAccount != viewer.key { preferences.activeAccount = viewer.key }
    }

    private func activate(token: String, viewer: Viewer, fetchedActivity: [String: Date]) {
        stopAccountTasks()
        persistence.use(account: viewer.key)
        remember(viewer)
        isAddingAccount = false
        let governor = RateGovernor()
        let file = viewer.host.isDotCom ? "subjects-\(viewer.login).sqlite" : "subjects-\(AppPaths.fileName(viewer.key)).sqlite"
        // Another schema starts the image again; a changed fragment does not
        // need to: the check misses only the new fields, and they are fetched.
        let image = Persistence(url: AppPaths.caches.appending(path: file), version: Types.schemaDigest)
        let environment = Baton.Environment(transport: GraphTransport(token: token, host: viewer.host, governor: governor), store: Store(persistence: image), releaseBufferSize: 50)
        let subjects = SubjectStore(environment: environment, viewerID: viewer.nodeID, fetchedActivity: fetchedActivity)
        subjects.onChange = { [weak self] in self?.scheduleRecompute() }
        rest = GitHubREST(token: token, host: viewer.host, governor: governor)
        batonImage = image
        use(environment, subjects: subjects, viewer: viewer)
        startPolling()
        startDispatching()
    }

    /// Shows an account's GraphQL side: Baton's environment and the subject
    /// store over it. Tests hand in an environment over a canned transport.
    func use(_ environment: Baton.Environment, subjects: SubjectStore, viewer: Viewer) {
        self.subjects = subjects
        graph = environment
        account = .signedIn(viewer)
        subjects.sync(Array(threads.values))
        recompute()
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

    // MARK: Projection

    /// Open pull requests that request the viewer with no notification
    /// thread; none in practice.
    var reviewRequests: [NotificationThread] {
        isPractice ? [] : subjects?.reviewRequestThreads ?? []
    }

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
            total: threads.count + reviewRequests.count,
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
                guard case .rule = dismissal.cause, case .thread(let threadID) = id, let thread = threads[threadID], thread.updatedAt <= dismissal.activity else { return nil }
                return ActionQueue.Target(item: id, activity: dismissal.activity)
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
                alert.informativeText = "You have \(updates.currentVersion). Update with:\n\(Updates.upgradeCommand)"
                alert.addButton(withTitle: "Copy Command")
                alert.addButton(withTitle: "Release Notes")
                alert.addButton(withTitle: "Later")
                NSApp.activate()
                switch alert.runModal() {
                case .alertFirstButtonReturn: updates.copyUpgradeCommand()
                case .alertSecondButtonReturn: openURL(release.url)
                default: break
                }
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

    /// Shows the row a banner named, by its key.
    func reveal(_ key: String?) {
        show(.split(.needsMe))
        guard let key else { return }
        let id = ItemID(key: key)
        if visibleItems.contains(where: { $0.id == id }) { select(.item(id)) }
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
        persistence.save { [weak self] in self?.persisted() ?? PersistedState() }
    }

    /// The account's inbox as saved. While practicing, that is the inbox set
    /// aside, so a save that lands then never writes made-up threads.
    private func persisted() -> PersistedState {
        var viewer: Viewer?
        if case .signedIn(let signedIn) = account { viewer = signedIn }
        if let stash = practiceStash {
            return PersistedState(viewer: viewer, threads: Array(stash.threads.values), state: stash.state, fetchedActivity: subjects?.fetchedActivity ?? [:])
        }
        return PersistedState(viewer: viewer, threads: Array(threads.values), state: state, fetchedActivity: subjects?.fetchedActivity ?? [:])
    }

    // MARK: Row data

    func lenses(for id: ItemID) -> SubjectStore.Lenses {
        if isPractice { return SubjectStore.Lenses() }
        return reminderLenses(id) ?? subjects?.lenses(for: id) ?? SubjectStore.Lenses()
    }

    func facts(for id: ItemID) -> SubjectFacts? {
        isPractice ? practiceFacts[id.key] : subjects?.facts(for: id)
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

    // MARK: Debugging

    #if DEBUG
    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Prints the inbox as classified, for checking rules against a real account.
    private func dump() {
        let counts = Split.allCases.map { "\($0.title) \(snapshot.count($0))" }.joined(separator: " · ")
        let enriched = threads.keys.filter { subjects?.facts(for: .thread($0)) != nil }.count
        let requests = subjects?.reviewRequestThreads.count ?? 0
        let mine = myPullRequestNodes.map { MyPullRequests.status($0.pullRequestStanding) }.map { PullRequestStanding.of($0).summary(now: .now) }
        log("[caton] my pull requests \(mine.count): \(mine.prefix(6).joined(separator: " | "))")
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
