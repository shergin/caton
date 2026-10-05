import CatonCore
import Foundation
import Testing
@testable import Caton

/// The model's verbs against threads set directly: no network, no Baton
/// (subjects are absent, so threads classify by reason alone), a throwaway
/// state file and user defaults, and a recorded browser.
/// A row by its key: a thread's id, or `followup:<node id>`.
func row(_ key: String) -> RowID { .item(ItemID(key: key)) }

extension RowID {
    /// A row as a short string, so expected layouts read as lists.
    var label: String {
        switch self {
        case .header(let title): "header:\(title)"
        case .item(let id): id.key
        case .bundle(.bot(let login)): "bundle:bot:\(login)"
        case .bundle(.repository(let name)): "bundle:repo:\(name)"
        case .pullRequest(let id): "pr:\(id)"
        }
    }
}

@MainActor
struct AppModelTests {
    final class Opened {
        var urls: [URL] = []
    }

    let opened = Opened()
    let model: AppModel
    let directory = FileManager.default.temporaryDirectory.appending(path: "caton-tests-\(UUID().uuidString)")

    /// A model signed in to a session connected to nothing, saving to a
    /// throwaway folder.
    init() {
        let opened = opened
        model = AppModel(
            preferences: Preferences(defaults: UserDefaults(suiteName: "caton-tests-\(UUID().uuidString)")!),
            persistence: StatePersistence(directory: directory),
            dryRun: false,
            openURL: { opened.urls.append($0) }
        )
        model.accounts.use(Session(
            viewer: Viewer(login: "me", nodeID: "U_me", scopes: ["repo"]),
            source: .local(facts: [:]),
            persistence: StatePersistence(directory: directory),
            dryRun: false
        ))
    }

    var session: Session { model.accounts.session! }

    func load(_ threads: [NotificationThread]) {
        session.threads = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        session.recompute()
    }

    func thread(_ id: String, reason: Reason = .mention, repository: String = "acme/web", age: TimeInterval = 0, title: String? = nil) -> NotificationThread {
        let parts = repository.split(separator: "/").map(String.init)
        return NotificationThread(
            id: id,
            repository: RepositoryName(owner: parts[0], name: parts[1]),
            kind: .issue,
            number: Int(id) ?? 1,
            title: title ?? "Thread \(id)",
            reason: reason,
            isUnread: true,
            updatedAt: Date.now.addingTimeInterval(-age),
            webURL: URL(string: "https://github.com/\(repository)/issues/\(id)")!
        )
    }

    /// Three Needs me threads, newest first: 1, 2, 3.
    func loadThree() {
        load([thread("1", age: 10), thread("2", age: 20), thread("3", age: 30)])
        model.panel.groupByRepository = false
        model.panel.selectFirst()
    }

    @Test func done_hides_the_row_at_once_and_selects_the_next() {
        loadThree()
        model.done()
        #expect(model.panel.items.map(\.id.key) == ["2", "3"])
        #expect(model.panel.selectedID == row("2"))
        #expect(session.state.queue.actions.map(\.verb) == [.done])
        #expect(model.needsMeCount == 2)
    }

    @Test func undo_brings_the_row_back_while_the_action_waits() {
        loadThree()
        model.done()
        model.undo()
        #expect(model.panel.items.map(\.id.key) == ["1", "2", "3"])
        #expect(session.state.queue.isEmpty)
        #expect(model.panel.selectedID == row("1"))
    }

    @Test func a_verb_applies_to_every_checked_row() {
        loadThree()
        model.panel.toggleChecked(row("1"))
        model.panel.toggleChecked(row("3"))
        model.done()
        #expect(model.panel.items.map(\.id.key) == ["2"])
        #expect(Set(session.state.queue.actions.map(\.batch)).count == 1)
        #expect(model.panel.checked.isEmpty)
    }

    @Test func practice_keeps_its_own_undo_and_the_account_gets_its_back() {
        loadThree()
        model.done()
        model.enterPractice()
        model.panel.selectFirst()
        model.done()
        model.exitPractice()
        model.undo()
        #expect(model.panel.items.map(\.id.key) == ["1", "2", "3"])
        #expect(session.state.queue.isEmpty)
    }

    @Test func snooze_hides_until_undone() {
        loadThree()
        model.snooze(until: .now.addingTimeInterval(3600))
        #expect(model.panel.items.map(\.id.key) == ["2", "3"])
        #expect(model.panel.count(.snoozed) == 1)
        model.undo()
        #expect(model.panel.items.count == 3)
    }

    @Test func open_records_the_page_and_shows_the_row_read() {
        loadThree()
        #expect(model.open())
        #expect(opened.urls.map(\.lastPathComponent) == ["1"])
        #expect(model.panel.items.first?.isUnread == false)
        #expect(session.state.queue.actions.map(\.verb) == [.markRead])
    }

    @Test func get_me_to_zero_never_clears_needs_me() {
        load([thread("1", age: 30 * 24 * 3600), thread("2", reason: .subscribed, age: 30 * 24 * 3600)])
        let options = model.zeroOptions
        #expect(options.allSatisfy { !$0.items.contains { $0.id == .thread("1") } })
        for option in options { model.getMeToZero(option) }
        #expect(model.needsMeCount == 1)
    }

    @Test func get_me_to_zero_previews_its_counts_and_clears_feed_with_one_undo() {
        load([thread("1"), thread("4", reason: .subscribed), thread("5", reason: .ciActivity, age: 2 * 24 * 3600)])
        model.panel.show(.split(.feed))
        let options = Dictionary(uniqueKeysWithValues: model.zeroOptions.map { ($0.key, $0.items.count) })
        #expect(options == ["1": 2, "2": 0, "3": 1, "4": 0, "5": 0])
        model.getMeToZero(model.zeroOptions[0])
        #expect(model.panel.items.isEmpty)
        #expect(session.state.cleared.count == 2)
        #expect(model.needsMeCount == 1)
        model.undo()
        #expect(model.panel.items.count == 2)
        #expect(session.state.cleared.isEmpty)
    }

    @Test func a_busy_feed_repository_is_one_row_that_done_clears_whole() {
        load((1...5).map { thread("\($0)", reason: .subscribed, age: Double($0)) } + [thread("8", reason: .subscribed, repository: "acme/api", age: 9), thread("9")])
        model.panel.show(.split(.feed))
        #expect(model.panel.rows.map(\.id.label) == ["bundle:repo:acme/web", "header:acme/api", "8"])
        #expect(model.panel.selectedID == .bundle(.repository("acme/web")))
        model.done()
        #expect(model.panel.rows.map(\.id.label) == ["header:acme/api", "8"])
        #expect(session.state.queue.actions.count == 5)
        #expect(model.needsMeCount == 1)
    }

    @Test func opening_a_bundle_shows_its_threads_and_left_closes_it() {
        load((1...4).map { thread("\($0)", reason: .subscribed, age: Double($0)) } + [thread("8", reason: .subscribed, repository: "acme/api", age: 9)])
        model.panel.show(.split(.feed))
        #expect(!press(special: .enter))
        #expect(model.panel.rows.count == 7)
        model.panel.moveSelection(by: 2)
        #expect(model.panel.selectedID == row("2"))
        model.panel.collapseSelection()
        #expect(model.panel.selectedID == .bundle(.repository("acme/web")))
        #expect(model.panel.rows.count == 3)
    }

    @Test func the_status_strip_shows_an_error_before_a_cooldown() {
        let until = Date.now.addingTimeInterval(120)
        session.noteCooldown(until)
        session.errorMessage = "Offline"
        #expect(model.statusMessage == .error("Offline"))
        model.dismissError()
        #expect(model.statusMessage == .cooldown(until: until))
    }

    @Test func the_menu_bar_summary_counts_every_split() {
        load([thread("1"), thread("2", reason: .teamMention), thread("3", reason: .subscribed)])
        #expect(model.countsSummary == "1 needs you · 1 team · 0 following · 1 feed")
    }

    @Test func a_saved_search_becomes_a_split_across_all_four() {
        load([thread("1", repository: "acme/web"), thread("2", reason: .subscribed, repository: "acme/web"), thread("3", repository: "acme/api")])
        model.panel.searchQuery = "repo:web"
        model.beginSavingSearch()
        #expect(model.panel.overlay == .saveSearch)
        model.saveSearch(named: "Web")
        guard case .saved(let id) = model.panel.section else { Issue.record("not on the saved split"); return }
        #expect(model.panel.searchQuery.isEmpty)
        #expect(Set(model.panel.items.map(\.id.key)) == ["1", "2"])
        #expect(model.panel.count(.saved(id)) == 2)
        model.panel.cycleSplit(by: 1)
        #expect(model.panel.section == .split(.needsMe))
        model.deleteSavedSearch(id)
        #expect(model.panel.tabs.count == 4)
    }

    @Test func practice_sets_the_inbox_aside_and_gives_it_back() {
        loadThree()
        model.enterPractice()
        #expect(model.isPractice)
        #expect(Split.allCases.map { model.inbox!.snapshot.count($0) } == [4, 2, 2, 11])
        model.done()
        #expect(model.needsMeCount == 3)
        #expect(model.open())
        #expect(opened.urls.isEmpty)
        model.exitPractice()
        #expect(!model.isPractice)
        #expect(model.needsMeCount == 3)
        #expect(model.panel.items.map(\.id.key) == ["1", "2", "3"])
        #expect(session.state.queue.isEmpty)
    }

    @Test func each_account_keeps_its_own_saved_inbox() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "caton-accounts-\(UUID().uuidString)")
        let persistence = StatePersistence(directory: directory)
        var first = PersistedState()
        first.threads = [thread("1")]
        persistence.use(account: "github.com/a")
        persistence.saveNow(first)
        persistence.use(account: "github.acme.com/b")
        #expect(persistence.load().threads.isEmpty)
        persistence.use(account: "github.com/a")
        #expect(persistence.load().threads.map(\.id) == ["1"])
        #expect(persistence.url.lastPathComponent == "state-github.com-a.json")
    }

    @Test func a_single_account_inbox_moves_to_its_name() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "caton-legacy-\(UUID().uuidString)")
        let persistence = StatePersistence(directory: directory)
        var legacy = PersistedState()
        legacy.threads = [thread("7")]
        persistence.saveNow(legacy)
        persistence.adoptLegacy(as: "github.com/a")
        #expect(!FileManager.default.fileExists(atPath: persistence.legacyURL.path))
        persistence.use(account: "github.com/a")
        #expect(persistence.load().threads.map(\.id) == ["7"])
    }

    @Test func practice_never_reaches_the_accounts_saved_inbox() async throws {
        load([thread("1")])
        model.enterPractice()
        model.done()
        try await Task.sleep(for: .milliseconds(700))
        let saved = StatePersistence(directory: directory).load()
        #expect(saved.threads.map(\.id) == ["1"])
        #expect(saved.state.queue.isEmpty)
    }

    func followUp(until: Date) -> FollowUp {
        FollowUp(until: until, answeredAt: nil, repository: RepositoryName(owner: "acme", name: "web"), number: 7, title: "Add caching", url: URL(string: "https://github.com/acme/web/pull/7")!)
    }

    @Test func a_due_reminder_joins_needs_me_until_done() {
        loadThree()
        session.state.followUps["PR_7"] = followUp(until: .now.addingTimeInterval(-60))
        session.recompute()
        let reminder = model.inbox!.snapshot.items(in: .needsMe).first { $0.id == .followUp("PR_7") }
        #expect(reminder?.classification.badge == .followUp)
        #expect(reminder?.resurfacing == .noActivity)
        #expect(model.needsMeCount == 4)
        model.done(row("followup:PR_7"))
        #expect(session.state.followUps.isEmpty)
        #expect(session.state.queue.isEmpty)
        #expect(model.needsMeCount == 3)
        model.undo()
        #expect(model.needsMeCount == 4)
    }

    @Test func a_reminder_not_yet_due_stays_out_and_snoozing_one_moves_it() {
        loadThree()
        session.state.followUps["PR_7"] = followUp(until: .now.addingTimeInterval(3600))
        session.recompute()
        #expect(model.needsMeCount == 3)
        session.state.followUps["PR_7"]?.until = .now.addingTimeInterval(-1)
        session.recompute()
        let later = Date.now.addingTimeInterval(7200)
        model.snooze(row("followup:PR_7"), until: later)
        #expect(session.state.followUps["PR_7"]?.until == later)
        #expect(model.needsMeCount == 3)
    }

    @Test func tab_cycles_through_the_splits() {
        loadThree()
        model.panel.cycleSplit(by: 1)
        #expect(model.panel.section == .split(.team))
        model.panel.cycleSplit(by: -2)
        #expect(model.panel.section == .split(.feed))
    }

    @Test func search_qualifiers_filter_the_visible_rows() {
        load([thread("1", repository: "acme/web", title: "Crash on launch"), thread("2", repository: "acme/api", title: "Crash in parser")])
        model.panel.searchQuery = "crash -repo:api"
        #expect(model.panel.items.map(\.id.key) == ["1"])
    }

    @Test func grouping_keeps_repository_order_while_the_panel_is_open() {
        load([thread("1", repository: "acme/web", age: 30), thread("2", repository: "acme/api", age: 10)])
        #expect(model.panel.items.map(\.id.key) == ["2", "1"])
        // New activity in acme/web would sort it first; the open panel keeps the order.
        load([thread("1", repository: "acme/web", age: 0), thread("2", repository: "acme/api", age: 10)])
        #expect(model.panel.items.map(\.id.key) == ["2", "1"])
    }

    @Test func selection_stays_on_its_row_when_the_list_changes() {
        loadThree()
        model.panel.select(row("2"))
        load([thread("0", age: 1), thread("1", age: 10), thread("2", age: 20), thread("3", age: 30)])
        #expect(model.panel.selectedID == row("2"))
    }
}
