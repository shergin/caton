import CatonCore
import Foundation
import Testing
@testable import Caton

/// The PRD's latency budget: a keystroke renders within 50 ms at 1,000
/// threads. These time what one keystroke asks of the model, at that size,
/// and print it; the bound is generous so a debug build passes, and the
/// printed numbers are what to compare.
@MainActor
struct SpeedTests {
    let model: AppModel

    init() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "caton-speed-\(UUID().uuidString)")
        model = AppModel(
            preferences: Preferences(defaults: UserDefaults(suiteName: "caton-speed-\(UUID().uuidString)")!),
            persistence: StatePersistence(directory: directory),
            openURL: { _ in }
        )
        let reasons: [Reason] = [.mention, .teamMention, .comment, .author, .subscribed, .subscribed, .ciActivity, .manual]
        var threads: [String: NotificationThread] = [:]
        for index in 0..<1_000 {
            let repository = "acme/repo\(index % 40)"
            let parts = repository.split(separator: "/").map(String.init)
            let thread = NotificationThread(
                id: String(10_000 + index),
                repository: RepositoryName(owner: parts[0], name: parts[1]),
                kind: index % 3 == 0 ? .issue : .pullRequest,
                number: index,
                title: "Thread number \(index) about caching and \(index % 7 == 0 ? "crashes" : "layout")",
                reason: reasons[index % reasons.count],
                isUnread: index % 2 == 0,
                updatedAt: Date.now.addingTimeInterval(-Double(index) * 600),
                webURL: URL(string: "https://github.com/\(repository)/issues/\(index)")!
            )
            threads[thread.id] = thread
        }
        model.threads = threads
        model.state.savedSearches = [SavedSearch(name: "Crashes", query: "crashes"), SavedSearch(name: "Repo 1", query: "repo:repo1")]
        model.recompute()
    }

    func time(_ label: String, repeat count: Int = 20, _ work: () -> Void) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<count { work() }
        let milliseconds = (clock.now - start) / .milliseconds(1) / Double(count)
        print("[speed] \(label): \(String(format: "%.2f", milliseconds)) ms")
        return milliseconds
    }

    /// What a `j` costs: move, then everything the panel reads to redraw.
    func keystroke() {
        model.moveSelection(by: 1)
        _ = model.visibleRows
        _ = model.selectedBundle
        for tab in model.tabs { _ = model.count(tab) }
        _ = model.statusMessage
    }

    @Test func a_keystroke_in_feed_stays_within_budget() {
        model.show(.split(.feed))
        let cost = time("keystroke in Feed (\(model.visibleItems.count) threads)", keystroke)
        #expect(cost < 50)
    }

    @Test func a_keystroke_while_searching_stays_within_budget() {
        model.show(.split(.following))
        model.searchQuery = "caching -repo:repo3"
        let cost = time("keystroke in Following, searching", keystroke)
        #expect(cost < 50)
    }

    /// Typing in the search field changes the list's inputs with every
    /// letter, so each one lays the list out again.
    @Test func typing_a_search_stays_within_budget() {
        model.show(.split(.feed))
        let letters = Array("caching layout")
        var typed = ""
        let cost = time("a letter typed into the search", repeat: letters.count) {
            typed.append(letters[typed.count])
            model.searchQuery = typed
            _ = model.visibleRows
        }
        #expect(cost < 50)
    }

    @Test func reclassifying_the_inbox_stays_within_budget() {
        let cost = time("recompute of 1,000 threads", repeat: 5) { model.recompute() }
        #expect(cost < 100)
    }
}
