import Foundation
import Testing
@testable import CatonCore

struct SearchQueryTests {
    func item(repository: String = "acme/web", kind: SubjectKind = .pullRequest, reason: Reason = .subscribed, unread: Bool = true, title: String? = nil) -> InboxItem {
        var thread = makeThread(repository: repository, kind: kind, reason: reason, unread: unread)
        if let title { thread.title = title }
        return InboxItem(thread: thread, classification: Classification(split: .feed, badge: .subscribed), isUnread: unread)
    }

    @Test func words_match_title_or_reference_and_all_must_hold() {
        let query = SearchQuery("crash web")
        #expect(query.matches(item(title: "Fix crash on launch"), facts: nil))
        #expect(!query.matches(item(repository: "acme/api", title: "Fix crash on launch"), facts: nil))
    }

    @Test func qualifiers_filter_and_a_minus_negates_them() {
        #expect(SearchQuery("repo:web").matches(item(), facts: nil))
        #expect(SearchQuery("repo:acme/web").matches(item(), facts: nil))
        #expect(!SearchQuery("-org:acme").matches(item(), facts: nil))
        #expect(SearchQuery("is:issue").matches(item(kind: .issue), facts: nil))
        #expect(!SearchQuery("is:issue").matches(item(), facts: nil))
    }

    @Test func reasons_take_friendly_aliases() {
        #expect(SearchQuery("reason:review").matches(item(reason: .reviewRequested), facts: nil))
        #expect(SearchQuery("reason:team_mention").matches(item(reason: .teamMention), facts: nil))
    }

    @Test func subject_qualifiers_read_the_facts() {
        let facts = makeFacts(isDraft: true, checks: .failure, author: "Octocat")
        #expect(SearchQuery("is:draft ci:failing author:octocat").matches(item(), facts: facts))
        #expect(!SearchQuery("-is:draft").matches(item(), facts: facts))
        #expect(!SearchQuery("is:draft").matches(item(), facts: nil))
    }

    @Test func an_unknown_qualifier_is_searched_as_text() {
        let query = SearchQuery("color:red")
        #expect(query.clauses == [.init(term: .text("color:red"), negated: false)])
    }

    @Test func quoted_phrases_stay_whole() {
        #expect(SearchQuery.tokens(#"repo:web "launch crash" -is:draft"#) == ["repo:web", "launch crash", "-is:draft"])
    }
}
