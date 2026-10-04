import CatonCore
import Foundation
import Testing
@testable import Caton

/// The model's verbs against threads set directly: no network, no Baton
/// (subjects are absent, so threads classify by reason alone), a throwaway
/// state file and user defaults, and a recorded browser.
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
            persistence: StatePersistence(url: directory.appending(path: "state.json")),
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
        #expect(model.visibleItems.map(\.id) == ["2", "3"])
        #expect(model.selectedID == "2")
        #expect(model.state.queue.actions.map(\.verb) == [.done])
        #expect(model.needsMeCount == 2)
    }

    @Test func undo_brings_the_row_back_while_the_action_waits() {
        loadThree()
        model.done()
        model.undo()
        #expect(model.visibleItems.map(\.id) == ["1", "2", "3"])
        #expect(model.state.queue.isEmpty)
        #expect(model.selectedID == "1")
    }

    @Test func a_verb_applies_to_every_checked_row() {
        loadThree()
        model.toggleChecked("1")
        model.toggleChecked("3")
        model.done()
        #expect(model.visibleItems.map(\.id) == ["2"])
        #expect(Set(model.state.queue.actions.map(\.batch)).count == 1)
        #expect(model.checked.isEmpty)
    }

    @Test func snooze_hides_until_undone() {
        loadThree()
        model.snooze(until: .now.addingTimeInterval(3600))
        #expect(model.visibleItems.map(\.id) == ["2", "3"])
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
        #expect(options.allSatisfy { !$0.items.contains { $0.id == "1" } })
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
        #expect(model.visibleRows.map(\.id) == ["bundle:repo:acme/web", "header:acme/api", "8"])
        #expect(model.selectedID == "bundle:repo:acme/web")
        model.done()
        #expect(model.visibleRows.map(\.id) == ["header:acme/api", "8"])
        #expect(model.state.queue.actions.count == 5)
        #expect(model.needsMeCount == 1)
    }

    @Test func opening_a_bundle_shows_its_threads_and_left_closes_it() {
        load((1...4).map { thread("\($0)", reason: .subscribed, age: Double($0)) } + [thread("8", reason: .subscribed, repository: "acme/api", age: 9)])
        model.show(.split(.feed))
        #expect(!model.open())
        #expect(model.visibleRows.count == 7)
        model.moveSelection(by: 2)
        #expect(model.selectedID == "2")
        model.collapseSelection()
        #expect(model.selectedID == "bundle:repo:acme/web")
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
        #expect(model.visibleItems.map(\.id) == ["1"])
    }

    @Test func grouping_keeps_repository_order_while_the_panel_is_open() {
        load([thread("1", repository: "acme/web", age: 30), thread("2", repository: "acme/api", age: 10)])
        #expect(model.visibleItems.map(\.id) == ["2", "1"])
        // New activity in acme/web would sort it first; the open panel keeps the order.
        load([thread("1", repository: "acme/web", age: 0), thread("2", repository: "acme/api", age: 10)])
        #expect(model.visibleItems.map(\.id) == ["2", "1"])
    }

    @Test func selection_stays_on_its_row_when_the_list_changes() {
        loadThree()
        model.select("2")
        load([thread("0", age: 1), thread("1", age: 10), thread("2", age: 20), thread("3", age: 30)])
        #expect(model.selectedID == "2")
    }
}
