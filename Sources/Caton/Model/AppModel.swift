import AppKit
import Baton
import CatonCore
import Observation

/// The app's root: the accounts and the session that shows, the panel, and
/// the commands views and keys run. A command finds its rows in the panel,
/// asks the session to change them, and says what happened.
///
/// The inbox itself (feed, local state, queue, writes) is `Session`; signing
/// in and switching accounts is `Accounts`; where the user is in the list is
/// `Panel`. This file holds the root, alerts and the status strip; the
/// commands are in `AppModel+Commands.swift` and, for My PRs,
/// `AppModel+PullRequests.swift`.
@MainActor
@Observable
final class AppModel {
    /// The one message the status strip shows, the most urgent first.
    enum StatusMessage: Equatable {
        case error(String)
        case cooldown(until: Date)
        case warning(String)
        case update(Updates.Release)
    }

    /// What the first sync of an account found, for the welcome summary.
    struct Welcome: Equatable {
        let total: Int
        let needsMe: Int
        let cleared: [Rule: Int]
    }

    // MARK: Observed state

    private(set) var welcome: Welcome?
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            if isPanelVisible {
                panel.forgetOrder()
                inbox?.refresh(force: false)
                inbox?.subjects?.searchReviewRequests(force: true)
                if welcome != nil { panel.overlay = .welcome } else { offerTips() }
            } else {
                panel.isSearching = false
                panel.clearChecked()
                if panel.overlay != .welcome { panel.overlay = .none }
            }
        }
    }
    /// The detached window is open but another window has the focus.
    var isWindowInBackground = false
    /// The practice inbox, while practicing: it shows in place of the account's.
    private(set) var practice: Session?

    let preferences: Preferences
    let accounts: Accounts
    let panel = Panel()
    let banners = Banners()
    let updates: Updates
    /// Opens the settings window; set by the app delegate.
    @ObservationIgnored var openSettings: (() -> Void)?
    /// Moves the inbox into a window, and back under the menu bar icon; set
    /// by the status item.
    @ObservationIgnored var detach: (() -> Void)?
    @ObservationIgnored var attach: (() -> Void)?
    /// Brings the panel (or the detached window) up; set by the status item.
    @ObservationIgnored var revealPanel: (() -> Void)?

    // MARK: Unobserved state

    /// What `z` takes back, newest last; it belongs to the session showing.
    @ObservationIgnored var undoStack: [Session.Undo] = []
    /// Opens a page; the browser by default.
    @ObservationIgnored let openURL: @MainActor (URL) -> Void
    /// No change reaches GitHub; for development against a real account.
    @ObservationIgnored let dryRun: Bool

    init(
        preferences: Preferences = Preferences(),
        persistence: StatePersistence = StatePersistence(),
        updates: Updates = Updates(),
        dryRun: Bool = ProcessInfo.processInfo.environment["CATON_DRY_RUN"] == "1",
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.preferences = preferences
        self.updates = updates
        self.dryRun = dryRun
        self.openURL = openURL
        accounts = Accounts(preferences: preferences, persistence: persistence, dryRun: dryRun)
        accounts.onSession = { [weak self] session in self?.adopt(session) }
    }

    // MARK: Sessions

    var account: Accounts.State { accounts.state }

    /// The session the panel shows: the practice inbox while practicing,
    /// else the signed-in account's.
    var inbox: Session? { practice ?? accounts.session }

    var isPractice: Bool { practice != nil }


    /// Baton's environment for the inbox, injected into views that own their
    /// queries.
    var graph: Baton.Environment? { inbox?.graph }

    func start() {
        banners.start()
        accounts.start()
    }

    /// Sends what the account's session has queued, for a quit.
    func drain() async {
        await accounts.session?.drain()
    }

    /// Takes a new account session: the panel starts over on it.
    private func adopt(_ session: Session?) {
        welcome = nil
        if let session { listen(to: session) }
        showInbox()
    }

    /// Points the panel at the session that shows; undo starts over with it.
    private func showInbox() {
        undoStack.removeAll()
        panel.session = inbox
    }

    private func listen(to session: Session) {
        session.onChange = { [weak self, weak session] left in
            guard let self, let session else { return }
            self.changed(session, leftNeedsMe: left)
        }
        session.onPoll = { [weak self, weak session] isFirst in
            guard let self, let session else { return }
            self.polled(session, isFirst: isFirst)
        }
        session.onWrite = { [weak self] message in self?.panel.toast(message) }
    }

    /// After a session classified its inbox again.
    private func changed(_ session: Session, leftNeedsMe: Set<ItemID>) {
        if session === inbox { panel.inboxChanged() }
        // Banners speak for the account, not the practice inbox.
        guard session === accounts.session else { return }
        if session.hasPolled { announce(session, baseline: false) }
        if !leftNeedsMe.isEmpty { banners.withdraw(Array(leftNeedsMe)) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CATON_DUMP"] == "1" { dump(session) }
        #endif
    }

    private func polled(_ session: Session, isFirst: Bool) {
        guard session === accounts.session else { return }
        if isFirst {
            // The session's first poll is the baseline: what is already
            // there is seen, not announced.
            announce(session, baseline: true)
            prepareWelcome(session)
        }
        offerDigest(session)
    }

    // MARK: Accounts

    func switchAccount(to key: String) {
        guard !isPractice else { return }
        Task {
            await accounts.switchTo(key)
            panel.toast("Switched to \(key)")
        }
    }

    /// The next account in the list, for the command menu.
    func switchToNextAccount() {
        guard let next = accounts.nextKey else {
            panel.toast("Only one account is signed in")
            return
        }
        switchAccount(to: next)
    }

    /// Shows the sign-in screen for another account, keeping this one.
    func addAccount() {
        Task {
            await accounts.add()
            revealPanel?()
        }
    }

    func signOut() {
        if isPractice { exitPractice() }
        accounts.signOut()
    }

    // MARK: Practice

    /// Shows a made-up inbox to learn the keys on, in place of the account's,
    /// which keeps running unseen and comes back as it was.
    func enterPractice() {
        guard practice == nil else { return }
        let session = Session.practice()
        listen(to: session)
        practice = session
        session.start()
        showInbox()
        panel.toast("Practice inbox: try e, h, u, x, z and ⌘K")
    }

    func exitPractice() {
        guard let session = practice else { return }
        session.stop()
        practice = nil
        showInbox()
    }

    // MARK: Alerts

    private func announce(_ session: Session, baseline: Bool) {
        let decision = AlertPolicy.decide(
            needsMe: session.snapshot.items(in: .needsMe),
            alerted: session.state.alerted,
            isPanelVisible: isPanelVisible && !isWindowInBackground && !isPractice,
            quietHours: preferences.quietHours,
            isEnabled: preferences.alertsEnabled,
            isBaseline: baseline,
            cap: preferences.alertCap,
            now: .now
        )
        session.markAlerted(decision.alerted)
        banners.show(decision)
    }

    /// The morning digest, once on a working day, if the user turned it on.
    private func offerDigest(_ session: Session, now: Date = .now) {
        guard preferences.digestEnabled, DigestPolicy.isDue(lastShown: preferences.lastDigest, quietHours: preferences.quietHours, now: now) else { return }
        // Overnight: since yesterday's digest, at most a day back.
        let since = preferences.lastDigest.map { max($0, now.addingTimeInterval(-24 * 3600)) } ?? now.addingTimeInterval(-16 * 3600)
        preferences.lastDigest = now
        let overnight = session.state.cleared.filter { $0.rule != nil && $0.at >= since }.count
        guard let message = DigestPolicy.message(needsMe: session.snapshot.count(.needsMe), clearedOvernight: overnight) else { return }
        banners.showDigest(message)
    }

    /// Shows the panel's welcome summary once per account, after its first sync.
    private func prepareWelcome(_ session: Session) {
        guard !preferences.welcomedAccounts.contains(session.viewer.login) else { return }
        welcome = Welcome(
            total: session.threads.count + session.reviewRequests.count,
            needsMe: session.snapshot.count(.needsMe),
            cleared: Dictionary(grouping: session.state.cleared.compactMap(\.rule), by: { $0 }).mapValues(\.count)
        )
        if isPanelVisible { panel.overlay = .welcome }
    }

    func finishWelcome(syncRuleClears: Bool) {
        preferences.syncRuleClears = syncRuleClears
        if let session = accounts.session { preferences.welcomedAccounts.insert(session.viewer.login) }
        welcome = nil
        panel.overlay = .none
        offerTips()
        if syncRuleClears { accounts.session?.syncRuleClearsToGitHub() }
    }

    /// "3 need you · 12 team · 8 following · 41 feed", for the menu bar's
    /// tooltip and VoiceOver: the account's, not the practice inbox's.
    var countsSummary: String {
        let snapshot = accounts.session?.snapshot ?? InboxSnapshot()
        let needsMe = snapshot.count(.needsMe)
        return [
            needsMe == 0 ? "nothing needs you" : "\(needsMe) need\(needsMe == 1 ? "s" : "") you",
            "\(snapshot.count(.team)) team",
            "\(snapshot.count(.following)) following",
            "\(snapshot.count(.feed)) feed",
        ].joined(separator: " · ")
    }

    /// The account's Needs me count, for the menu bar.
    var needsMeCount: Int { accounts.session?.snapshot.count(.needsMe) ?? 0 }

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
        guard !preferences.tipsShown, case .signedIn = account, panel.overlay == .none else { return }
        panel.overlay = .tips
    }

    func dismissTips() {
        preferences.tipsShown = true
        if panel.overlay == .tips { panel.overlay = .none }
    }

    /// Shows the row a banner named, by its key.
    func reveal(_ key: String?) {
        panel.show(.split(.needsMe))
        guard let key else { return }
        let id = ItemID(key: key)
        if panel.items.contains(where: { $0.id == id }) { panel.select(.item(id)) }
    }

    // MARK: Feedback

    var errorMessage: String? { inbox?.errorMessage }

    func dismissError() { inbox?.errorMessage = nil }

    /// What the status strip shows: an error, else a cooldown, else a
    /// warning, else an available update.
    var statusMessage: StatusMessage? {
        if let errorMessage { return .error(errorMessage) }
        if let cooldownUntil = inbox?.cooldownUntil, cooldownUntil > .now { return .cooldown(until: cooldownUntil) }
        if let warning { return .warning(warning) }
        if let release = updates.available { return .update(release) }
        return nil
    }

    private var warning: String? {
        if let status = preferences.hotKeyStatus { return status }
        let retrying = inbox?.state.queue.actions.filter { $0.attempts > 0 }.count ?? 0
        if retrying > 0 { return retrying == 1 ? "1 change is waiting to reach GitHub." : "\(retrying) changes are waiting to reach GitHub." }
        return nil
    }

    // MARK: Row data

    func lenses(for id: ItemID) -> SubjectStore.Lenses { inbox?.lenses(for: id) ?? SubjectStore.Lenses() }

    func facts(for id: ItemID) -> SubjectFacts? { inbox?.facts(for: id) }

    func spokenState(for item: InboxItem) -> String { inbox?.spokenState(for: item) ?? "" }

    // MARK: Debugging

    #if DEBUG
    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Prints the inbox as classified, for checking rules against a real account.
    private func dump(_ session: Session) {
        let snapshot = session.snapshot
        let counts = Split.allCases.map { "\($0.title) \(snapshot.count($0))" }.joined(separator: " · ")
        let enriched = session.threads.keys.filter { session.facts(for: .thread($0)) != nil }.count
        let mine = session.myPullRequestNodes.map { MyPullRequests.status($0.pullRequestStanding) }.map { PullRequestStanding.of($0).summary(now: .now) }
        log("[caton] my pull requests \(mine.count): \(mine.prefix(6).joined(separator: " | "))")
        log("[caton] threads \(session.threads.count), enriched \(enriched), review requests \(session.reviewRequests.count), cleared \(session.state.cleared.count), snoozed \(snapshot.snoozed.count) | \(counts)")
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
