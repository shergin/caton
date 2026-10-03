import Foundation
import Testing
@testable import CatonCore

struct GitHubRESTTests {
    @Test func a_poll_asks_for_fifty_and_follows_every_page() async throws {
        let client = StubHTTPClient([
            .init(status: 200, body: "[\(notificationJSON(id: "1"))]", headers: [
                "Last-Modified": "Wed, 01 Oct 2026 10:00:00 GMT",
                "X-Poll-Interval": "90",
                "Link": #"<https://api.github.com/notifications?page=2>; rel="next""#,
            ]),
            .init(status: 200, body: "[\(notificationJSON(id: "2", type: "Issue", number: 7))]"),
        ])
        let rest = GitHubREST(token: "t", client: client)
        let poll = try await rest.pollUnread()
        guard case .changed(let threads) = poll else { Issue.record("expected threads"); return }
        #expect(threads.map(\.id) == ["1", "2"])
        #expect(threads[1].kind == .issue)
        #expect(threads[1].webURL.absoluteString == "https://github.com/acme/web/issues/7")
        #expect(client.recorded[0].url?.query()?.contains("per_page=50") == true)
        #expect(await rest.pollInterval == 90)
    }

    @Test func an_unchanged_feed_is_asked_conditionally_and_answers_not_modified() async throws {
        let client = StubHTTPClient([
            .init(status: 200, body: "[]", headers: ["Last-Modified": "Wed, 01 Oct 2026 10:00:00 GMT"]),
            .init(status: 304, body: ""),
        ])
        let rest = GitHubREST(token: "t", client: client)
        _ = try await rest.pollUnread()
        #expect(try await rest.pollUnread() == .notModified)
        #expect(client.recorded[1].value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 01 Oct 2026 10:00:00 GMT")
    }

    @Test func a_next_page_outside_the_api_host_is_refused() async {
        let client = StubHTTPClient([
            .init(status: 200, body: "[]", headers: ["Link": #"<https://evil.example/notifications?page=2>; rel="next""#]),
        ])
        let rest = GitHubREST(token: "t", client: client)
        await #expect(throws: GitHubError.untrustedURL) { try await rest.pollUnread() }
    }

    @Test func a_retry_after_blocks_every_request_until_it_passes() async {
        let clock = Clock(reference)
        let governor = RateGovernor(now: { clock.now })
        let client = StubHTTPClient([
            .init(status: 429, body: #"{"message":"secondary rate limit"}"#, headers: ["Retry-After": "30"]),
        ])
        let rest = GitHubREST(token: "t", client: client, governor: governor)
        await #expect(throws: GitHubError.rateLimited(until: reference.addingTimeInterval(30))) { try await rest.markDone(threadID: "1") }
        await #expect(throws: GitHubError.rateLimited(until: reference.addingTimeInterval(30))) { try await rest.markDone(threadID: "1") }
        #expect(client.recorded.count == 1)
    }

    @Test func unsubscribe_deletes_the_subscription_rather_than_ignoring_it() async throws {
        let client = StubHTTPClient([.init(status: 204, body: "")])
        let rest = GitHubREST(token: "t", client: client)
        try await rest.unsubscribe(threadID: "123")
        #expect(client.recorded[0].httpMethod == "DELETE")
        #expect(client.recorded[0].url?.path() == "/notifications/threads/123/subscription")
    }

    @Test func a_token_without_notification_scopes_is_refused() async {
        let client = StubHTTPClient([
            .init(status: 200, body: #"{"login":"me","node_id":"U_1"}"#, headers: ["X-OAuth-Scopes": "gist, read:org"]),
        ])
        let rest = GitHubREST(token: "t", client: client)
        await #expect(throws: GitHubError.missingScopes(["notifications"])) { try await rest.viewer() }
    }

    @Test func an_unknown_reason_decodes_as_unknown() throws {
        let threads = try NotificationDecoding.threads(from: Data("[\(notificationJSON(id: "1", reason: "something_new"))]".utf8))
        #expect(threads[0].reason == .unknown)
    }
}

final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
