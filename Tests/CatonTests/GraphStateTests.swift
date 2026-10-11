import Baton
import BatonTesting
import CatonCore
import Foundation
import Testing
@testable import Caton

@MainActor
struct GraphStateTests {
    @Test func a_poll_shares_the_query_already_fetching_for_my_pull_requests() async throws {
        let transport = ScriptedTransport([ReviewRequestsQuery.name: Data(#"{"data":{"search":{"nodes":[]}}}"#.utf8)])
        transport.hold(MyPullRequestsQuery.name)
        let graph = Baton.Environment(transport: transport)
        let subjects = SubjectStore(environment: graph, viewerID: "U_me", fetchedActivity: [:])
        #expect(await wait(until: { transport.held.count == 1 }))
        subjects.searchReviewRequests()
        #expect(await wait(until: { transport.requests.contains { $0.operationName == ReviewRequestsQuery.name } }))
        try #require(transport.held.first).respond(ImageTests.response)
        #expect(await wait(until: {
            if case .ready = subjects.myPullRequests.phase { return true }
            return false
        }))
        #expect(transport.requests.filter { $0.operationName == MyPullRequestsQuery.name }.count == 1)
        subjects.releaseAll()
        await graph.end()
    }

    @Test func a_response_from_another_operation_reclassifies_the_inbox() async throws {
        let graph = Baton.Environment(transport: WriteTests.github())
        let operation = IssueSubjectQuery(owner: "acme", name: "web", number: 7)
        try await graph.commitPayload(operation, Payload(Data(#"""
            {"data":{"repository":{"id":"R_web","issue":{"id":"I_7","state":"OPEN","stateReason":null,
            "viewerDidAuthor":false,"author":null,"comments":{"nodes":[]}}}}}
            """#.utf8)))
        let subjects = SubjectStore(environment: graph, viewerID: "U_me", fetchedActivity: [:])
        let session = Session(
            viewer: Viewer(login: "me", nodeID: "U_me", scopes: ["repo"]),
            source: .github(.init(rest: GitHubREST(token: "test", client: NotModified()), graph: graph, subjects: subjects, image: nil)),
            persistence: nil, dryRun: true
        )
        session.threads["T_7"] = NotificationThread(
            id: "T_7", repository: RepositoryName(owner: "acme", name: "web"), kind: .issue, number: 7,
            title: "An issue", reason: .subscribed, isUnread: true, updatedAt: .now,
            webURL: URL(string: "https://github.com/acme/web/issues/7")!
        )
        session.start()
        #expect(session.state.dismissals[.thread("T_7")] == nil)
        #expect(session.facts(for: .thread("T_7"))?.state == .open)

        try await graph.commitPayload(IssueRefreshQuery(ids: ["I_7"]), Payload(Data(#"""
            {"data":{"nodes":[{"__typename":"Issue","id":"I_7","state":"CLOSED","stateReason":"COMPLETED"}]}}
            """#.utf8)))
        #expect(await wait(until: { session.state.dismissals[.thread("T_7")] != nil }))
        await session.end()
    }

    @Test func a_comment_loaded_by_peek_cancels_a_reminder_without_waiting_for_a_poll() async throws {
        let test = WriteTests()
        try await test.open()
        test.model.remind("PR_7", until: .now.addingTimeInterval(-1))
        #expect(test.model.inbox?.followUp(for: "PR_7") != nil)
        let commentAt = Date.now.formatted(.iso8601)
        try await test.environment.commitPayload(PeekPullRequestQuery(owner: "acme", name: "web", number: 7), Payload(Data("""
            {"data":{"repository":{"id":"R_web","pullRequest":{"id":"PR_7","comments":{"nodes":[{
            "id":"C_1","author":{"__typename":"User","id":"U_alex","login":"alex"},
            "bodyText":"Ready","createdAt":"\(commentAt)"}]}}}}}
            """.utf8)))
        let node = try #require(test.model.myPullRequestNode("PR_7"))
        #expect(MyPullRequests.status(node.pullRequestStanding).lastComment?.login == "alex")
        #expect(await wait(until: { test.model.inbox?.followUp(for: "PR_7") == nil }))
        #expect(MyPullRequests.status(node.pullRequestStanding).lastComment?.login == "alex")
        await test.model.inbox?.end()
    }

    @Test func a_failed_refresh_keeps_cached_rows_and_exposes_its_failure() async throws {
        let graph = Baton.Environment(transport: RecordedTransport())
        try await graph.commitPayload(MyPullRequestsQuery(), Payload(ImageTests.response))
        let handle = graph.handle(for: MyPullRequestsQuery(), fetchPolicy: .storeOnly)
        let retention = handle.retain()
        await #expect(throws: (any Error).self) { try await handle.refetch() }
        guard case .ready(let data) = handle.phase else { Issue.record("Cached rows disappeared"); return }
        #expect(data.viewer.myPullRequestList.pullRequests.nodes.first?.id == "PR_7")
        guard case .transport = handle.fetch.failure else { Issue.record("Missing transport failure"); return }
        withExtendedLifetime(retention) {}
        await graph.end()
    }

    @Test func unknown_enums_and_malformed_dates_do_not_invent_subject_state() async throws {
        let response = Data(String(decoding: ImageTests.response, as: UTF8.self)
            .replacingOccurrences(of: "REVIEW_REQUIRED", with: "FUTURE_DECISION")
            .replacingOccurrences(of: "MERGEABLE", with: "FUTURE_MERGEABILITY")
            .replacingOccurrences(of: "2026-10-01T10:00:00Z", with: "not-a-date").utf8)
        let graph = Baton.Environment(transport: RecordedTransport())
        graph.log = nil
        try await graph.commitPayload(MyPullRequestsQuery(), Payload(response))
        let handle = graph.handle(for: MyPullRequestsQuery(), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else { Issue.record("Expected cached data"); return }
        let node = try #require(data.viewer.myPullRequestList.pullRequests.nodes.first)
        let status = MyPullRequests.status(node.pullRequestStanding)
        #expect(node.url == URL(string: "https://github.com/acme/web/pull/7"))
        #expect(status.reviewDecision == nil)
        #expect(status.mergeable == .unknown)
        #expect(status.requestedAt == nil)
        await graph.end()
    }
}
