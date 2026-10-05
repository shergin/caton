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

    init() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "caton-tests-\(UUID().uuidString)")
        let opened = opened
        model = AppModel(
            preferences: Preferences(defaults: UserDefaults(suiteName: "caton-tests-\(UUID().uuidString)")!),
            persistence: StatePersistence(directory: directory),
            openURL: { opened.urls.append($0) }
        )
    }

    func load(_ threads: [NotificationThread]) {
        model.threads = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        model.recompute()
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
        model.groupByRepository = false
        model.selectFirst()
    }

    @Test func done_hides_the_row_at_once_and_selects_the_next() {
        loadThree()
        model.done()
        #expect(model.visibleItems.map(\.id.key) == ["2", "3"])
        #expect(model.selectedID == row("2"))
        #expect(model.state.queue.actions.map(\.verb) == [.done])
        #expect(model.needsMeCount == 2)
    }

    @Test func undo_brings_the_row_back_while_the_action_waits() {
        loadThree()
        model.done()
        model.undo()
        #expect(model.visibleItems.map(\.id.key) == ["1", "2", "3"])
        #expect(model.state.queue.isEmpty)
        #expect(model.selectedID == row("1"))
    }

    @Test func a_verb_applies_to_every_checked_row() {
        loadThree()
        model.toggleChecked(row("1"))
        model.toggleChecked(row("3"))
        model.done()
        #expect(model.visibleItems.map(\.id.key) == ["2"])
        #expect(Set(model.state.queue.actions.map(\.batch)).count == 1)
        #expect(model.checked.isEmpty)
    }

    @Test func snooze_hides_until_undone() {
        loadThree()
        model.snooze(until: .now.addingTimeInterval(3600))
        #expect(model.visibleItems.map(\.id.key) == ["2", "3"])
        #expect(model.count(.snoozed) == 1)
        model.undo()
        #expect(model.visibleItems.count == 3)
    }

    @Test func open_records_the_page_and_shows_the_row_read() {
        loadThree()
        #expect(model.open())
        #expect(opened.urls.map(\.lastPathComponent) == ["1"])
        #expect(model.visibleItems.first?.isUnread == false)
        #expect(model.state.queue.actions.map(\.verb) == [.markRead])
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
        model.show(.split(.feed))
        let options = Dictionary(uniqueKeysWithValues: model.zeroOptions.map { ($0.key, $0.items.count) })
        #expect(options == ["1": 2, "2": 0, "3": 1, "4": 0, "5": 0])
        model.getMeToZero(model.zeroOptions[0])
        #expect(model.visibleItems.isEmpty)
        #expect(model.cleared.count == 2)
        #expect(model.needsMeCount == 1)
        model.undo()
        #expect(model.visibleItems.count == 2)
        #expect(model.cleared.isEmpty)
    }

    @Test func a_busy_feed_repository_is_one_row_that_done_clears_whole() {
        load((1...5).map { thread("\($0)", reason: .subscribed, age: Double($0)) } + [thread("8", reason: .subscribed, repository: "acme/api", age: 9), thread("9")])
        model.show(.split(.feed))
        #expect(model.visibleRows.map(\.id.label) == ["bundle:repo:acme/web", "header:acme/api", "8"])
        #expect(model.selectedID == .bundle(.repository("acme/web")))
        model.done()
        #expect(model.visibleRows.map(\.id.label) == ["header:acme/api", "8"])
        #expect(model.state.queue.actions.count == 5)
        #expect(model.needsMeCount == 1)
    }

    @Test func opening_a_bundle_shows_its_threads_and_left_closes_it() {
        load((1...4).map { thread("\($0)", reason: .subscribed, age: Double($0)) } + [thread("8", reason: .subscribed, repository: "acme/api", age: 9)])
        model.show(.split(.feed))
        #expect(!model.open())
        #expect(model.visibleRows.count == 7)
        model.moveSelection(by: 2)
        #expect(model.selectedID == row("2"))
        model.collapseSelection()
        #expect(model.selectedID == .bundle(.repository("acme/web")))
        #expect(model.visibleRows.count == 3)
    }

    @Test func the_status_strip_shows_an_error_before_a_cooldown() {
        let until = Date.now.addingTimeInterval(120)
        model.noteCooldown(until)
        model.errorMessage = "Offline"
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
        model.searchQuery = "repo:web"
        model.beginSavingSearch()
        #expect(model.overlay == .saveSearch)
        model.saveSearch(named: "Web")
        guard case .saved(let id) = model.section else { Issue.record("not on the saved split"); return }
        #expect(model.searchQuery.isEmpty)
        #expect(Set(model.visibleItems.map(\.id.key)) == ["1", "2"])
        #expect(model.count(.saved(id)) == 2)
        model.cycleSplit(by: 1)
        #expect(model.section == .split(.needsMe))
        model.deleteSavedSearch(id)
        #expect(model.tabs.count == 4)
    }

    @Test func practice_sets_the_inbox_aside_and_gives_it_back() {
        loadThree()
        model.enterPractice()
        #expect(model.isPractice)
        #expect(Split.allCases.map { model.snapshot.count($0) } == [4, 2, 2, 11])
        model.done()
        #expect(model.needsMeCount == 3)
        #expect(model.open())
        #expect(opened.urls.isEmpty)
        model.exitPractice()
        #expect(!model.isPractice)
        #expect(model.needsMeCount == 3)
        #expect(model.visibleItems.map(\.id.key) == ["1", "2", "3"])
        #expect(model.state.queue.isEmpty)
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

    @Test func a_save_during_practice_writes_the_real_inbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "caton-practice-\(UUID().uuidString)")
        let persistence = StatePersistence(directory: directory)
        let model = AppModel(
            preferences: Preferences(defaults: UserDefaults(suiteName: "caton-tests-\(UUID().uuidString)")!),
            persistence: persistence,
            openURL: { _ in }
        )
        model.threads = ["1": thread("1")]
        model.recompute()
        model.enterPractice()
        model.done()
        try await Task.sleep(for: .milliseconds(700))
        #expect(persistence.load().threads.map(\.id) == ["1"])
        #expect(persistence.load().state.queue.isEmpty)
    }

    func followUp(until: Date) -> FollowUp {
        FollowUp(until: until, answeredAt: nil, repository: RepositoryName(owner: "acme", name: "web"), number: 7, title: "Add caching", url: URL(string: "https://github.com/acme/web/pull/7")!)
    }

    @Test func a_due_reminder_joins_needs_me_until_done() {
        loadThree()
        model.state.followUps["PR_7"] = followUp(until: .now.addingTimeInterval(-60))
        model.recompute()
        let reminder = model.snapshot.items(in: .needsMe).first { $0.id == .followUp("PR_7") }
        #expect(reminder?.classification.badge == .followUp)
        #expect(reminder?.resurfacing == .noActivity)
        #expect(model.needsMeCount == 4)
        model.done(row("followup:PR_7"))
        #expect(model.state.followUps.isEmpty)
        #expect(model.state.queue.isEmpty)
        #expect(model.needsMeCount == 3)
        model.undo()
        #expect(model.needsMeCount == 4)
    }

    @Test func a_reminder_not_yet_due_stays_out_and_snoozing_one_moves_it() {
        loadThree()
        model.state.followUps["PR_7"] = followUp(until: .now.addingTimeInterval(3600))
        model.recompute()
        #expect(model.needsMeCount == 3)
        model.state.followUps["PR_7"]?.until = .now.addingTimeInterval(-1)
        model.recompute()
        let later = Date.now.addingTimeInterval(7200)
        model.snooze(row("followup:PR_7"), until: later)
        #expect(model.state.followUps["PR_7"]?.until == later)
        #expect(model.needsMeCount == 3)
    }

    @Test func tab_cycles_through_the_splits() {
        loadThree()
        model.cycleSplit(by: 1)
        #expect(model.section == .split(.team))
        model.cycleSplit(by: -2)
        #expect(model.section == .split(.feed))
    }

    @Test func search_qualifiers_filter_the_visible_rows() {
        load([thread("1", repository: "acme/web", title: "Crash on launch"), thread("2", repository: "acme/api", title: "Crash in parser")])
        model.searchQuery = "crash -repo:api"
        #expect(model.visibleItems.map(\.id.key) == ["1"])
    }

    @Test func grouping_keeps_repository_order_while_the_panel_is_open() {
        load([thread("1", repository: "acme/web", age: 30), thread("2", repository: "acme/api", age: 10)])
        #expect(model.visibleItems.map(\.id.key) == ["2", "1"])
        // New activity in acme/web would sort it first; the open panel keeps the order.
        load([thread("1", repository: "acme/web", age: 0), thread("2", repository: "acme/api", age: 10)])
        #expect(model.visibleItems.map(\.id.key) == ["2", "1"])
    }

    @Test func selection_stays_on_its_row_when_the_list_changes() {
        loadThree()
        model.select(row("2"))
        load([thread("0", age: 1), thread("1", age: 10), thread("2", age: 20), thread("3", age: 30)])
        #expect(model.selectedID == row("2"))
    }
}
