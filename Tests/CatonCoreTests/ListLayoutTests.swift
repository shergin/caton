import Foundation
import Testing
@testable import CatonCore

struct ListLayoutTests {
    func item(_ id: String, repository: String = "acme/web", unread: Bool = true) -> InboxItem {
        InboxItem(thread: makeThread(id: id, repository: repository, unread: unread), classification: Classification(split: .feed, badge: .subscribed), isUnread: unread)
    }

    func rows(_ items: [InboxItem], grouped: Bool = true, bundles: Bool = true, expanded: Set<String> = [], bots: [String: String] = [:]) -> [ListRow] {
        ListLayout.rows(items, groupByRepository: grouped, bundles: bundles, expanded: expanded) { bots[$0.id] }
    }

    @Test func a_bot_with_two_threads_becomes_one_row_across_repositories() {
        let layout = rows(
            [item("1", repository: "acme/web"), item("2", repository: "acme/api"), item("3")],
            bots: ["1": "dependabot[bot]", "2": "dependabot[bot]"]
        )
        #expect(layout.map(\.id) == ["header:Bots", "bundle:bot:dependabot[bot]", "header:acme/web", "3"])
    }

    @Test func a_bot_with_one_thread_stays_a_thread() {
        let layout = rows([item("1"), item("2")], bots: ["1": "renovate[bot]"])
        #expect(layout.map(\.id) == ["header:acme/web", "1", "2"])
    }

    @Test func a_busy_repository_collapses_in_place_of_its_header() {
        let layout = rows([item("1"), item("2"), item("3"), item("4"), item("5", repository: "acme/api")])
        #expect(layout.map(\.id) == ["bundle:repo:acme/web", "header:acme/api", "5"])
    }

    @Test func a_lone_repository_is_not_hidden_behind_a_bundle() {
        let layout = rows([item("1"), item("2"), item("3"), item("4")])
        #expect(layout.map(\.id) == ["header:acme/web", "1", "2", "3", "4"])
    }

    @Test func an_open_bundle_lists_its_threads_beneath_it() {
        let layout = rows([item("1"), item("2"), item("3"), item("4"), item("5", repository: "acme/api")], expanded: ["bundle:repo:acme/web"])
        #expect(layout.map(\.id) == ["bundle:repo:acme/web", "1", "2", "3", "4", "header:acme/api", "5"])
        guard case .item(_, let depth) = layout[1] else { Issue.record("not a thread"); return }
        #expect(depth == 1)
    }

    @Test func without_bundles_the_list_only_groups() {
        let layout = rows([item("1"), item("2"), item("3"), item("4")], bundles: false, bots: ["1": "bot", "2": "bot"])
        #expect(layout.map(\.id) == ["header:acme/web", "1", "2", "3", "4"])
    }

    @Test func ungrouped_bundles_skip_headers() {
        let layout = rows([item("1"), item("2"), item("3")], grouped: false, bots: ["1": "bot", "2": "bot"])
        #expect(layout.map(\.id) == ["bundle:bot:bot", "3"])
    }

    @Test func a_bundle_counts_its_unread_threads() {
        let bundle = ThreadBundle(kind: .bot("bot"), items: [item("1"), item("2", unread: false)])
        #expect(bundle.unreadCount == 1)
    }
}
