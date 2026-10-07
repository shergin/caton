import Baton
import BatonTesting
import CatonCore
import Foundation
import Testing
@testable import Caton

/// GitHub's REST feed with nothing new: every poll is a 304.
struct NotModified: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// Nudge end to end through Baton, against a canned GitHub: the undo window
/// holds the write, the optimistic response shows the moment it is sent,
/// GitHub's answer replaces it, and a refusal takes it back.
@MainActor
struct WriteTests {
    static func github(myPullRequests: Data = ImageTests.response) -> ScriptedTransport {
        ScriptedTransport([
            MyPullRequestsQuery.name: myPullRequests,
            ReviewRequestsQuery.name: Data(#"{"data":{"search":{"nodes":[]}}}"#.utf8),
        ])
    }

    nonisolated static let answered = Data(#"""
        {"data":{"requestReviews":{"pullRequest":{"id":"PR_7",
          "reviewRequests":{"nodes":[
            {"id":"RR_1","requestedReviewer":{"__typename":"User","__isActor":"User","login":"alex","id":"U_alex","__isNode":"User"}},
            {"id":"RR_2","requestedReviewer":{"__typename":"Team","slug":"web","organization":{"login":"acme","id":"O_acme"},"id":"T_web","__isNode":"Team"}}
          ]},
          "timelineItems":{"nodes":[{"__typename":"ReviewRequestedEvent","createdAt":"2026-10-04T08:00:00Z","__isNode":"ReviewRequestedEvent","id":"RRE_2"}]}
        }}}}
        """#.utf8)

    let github: ScriptedTransport
    let model: AppModel
    let environment: Baton.Environment

    init() {
        self.init(github: Self.github())
    }

    init(github: ScriptedTransport) {
        self.github = github
        let directory = FileManager.default.temporaryDirectory.appending(path: "caton-writes-\(UUID().uuidString)")
        model = AppModel(
            preferences: Preferences(defaults: UserDefaults(suiteName: "caton-writes-\(UUID().uuidString)")!),
            persistence: StatePersistence(directory: directory),
            dryRun: false,
            openURL: { _ in }
        )
        environment = Baton.Environment(transport: github)
    }

    func open() async throws {
        let subjects = SubjectStore(environment: environment, viewerID: "U_me", fetchedActivity: [:])
        // The feed answers that nothing changed; only GraphQL is played.
        let rest = GitHubREST(token: "test", client: NotModified())
        let session = Session(
            viewer: Viewer(login: "me", nodeID: "U_me", scopes: ["repo"]),
            source: .github(.init(rest: rest, graph: environment, subjects: subjects, image: nil)),
            persistence: nil,
            dryRun: false
        )
        session.writeGrace = .milliseconds(50)
        model.accounts.use(session)
        try await subjects.myPullRequests.refetch()
        model.panel.show(.myPullRequests)
        model.panel.select(.pullRequest("PR_7"))
    }

    var requestedAt: Date? {
        model.myPullRequestNode("PR_7").flatMap { MyPullRequests.status($0.pullRequestStanding).requestedAt }
    }

    @Test func undo_inside_the_window_sends_nothing() async throws {
        try await open()
        model.nudge()
        #expect(model.pendingWriteNote(for: "PR_7") == "asking again…")
        model.undo()
        #expect(model.inbox!.pendingWrites.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(github.requests(of: .mutation).isEmpty)
        await model.inbox?.end()
    }

    @Test func a_nudge_shows_at_once_then_takes_githubs_answer() async throws {
        try await open()
        let before = try #require(requestedAt)
        model.nudge()
        #expect(await wait(until: { !github.held.isEmpty }))
        let request = try #require(github.requests(of: .mutation).first)
        #expect(request.operationName == "NudgeReviewersMutation")
        #expect(request.variables.json.contains("U_alex") && request.variables.json.contains("T_web"))
        #expect(request.variables.values["input"] == .object([
            "pullRequestId": .string("PR_7"), "userIds": .list([.string("U_alex")]),
            "teamIds": .list([.string("T_web")]), "botIds": .list([]), "union": .bool(true),
        ]))
        guard case .text(let document) = request.document else { Issue.record("GitHub needs operation text"); return }
        #expect(!document.contains("catonNudgedAt"))

        // Sent, not answered: the optimistic response is what the row reads.
        let optimistic = try #require(requestedAt)
        #expect(optimistic > before)
        #expect(Date.now.timeIntervalSince(optimistic) < 60)

        try #require(github.held.first).respond(Self.answered)
        #expect(await wait(until: { requestedAt == (try? Date("2026-10-04T08:00:00Z", strategy: .iso8601)) }))
        #expect(requestedAt == (try? Date("2026-10-04T08:00:00Z", strategy: .iso8601)))
        #expect(model.errorMessage == nil)
        await model.inbox?.end()
    }

    @Test func a_refused_nudge_is_taken_back_and_said() async throws {
        try await open()
        let before = try #require(requestedAt)
        model.nudge()
        #expect(await wait(until: { !github.held.isEmpty }))
        #expect(try #require(requestedAt) > before)
        try #require(github.held.first).refuse(TransportError(statusCode: 422, body: "Review cannot be requested from pull request author."))
        #expect(await wait(until: { model.errorMessage != nil }))
        #expect(requestedAt == before)
        #expect(model.errorMessage?.hasPrefix("Couldn't change acme/web#7") == true)
        await model.inbox?.end()
    }

    @Test func ready_for_review_moves_the_draft_out_of_drafts_at_once() async throws {
        let draft = Data(String(decoding: ImageTests.response, as: UTF8.self).replacingOccurrences(of: #""isDraft":false"#, with: #""isDraft":true"#).utf8)
        let test = WriteTests(github: Self.github(myPullRequests: draft))
        try await test.open()
        func group() -> PullRequestStanding.Group? {
            test.model.myPullRequestNode("PR_7").map { PullRequestStanding.of(MyPullRequests.status($0.pullRequestStanding)).group }
        }
        #expect(group() == .drafts)
        test.model.nudge()
        #expect(test.model.inbox!.pendingWrites.isEmpty)
        test.model.markReadyForReview()
        #expect(await wait(until: { !test.github.held.isEmpty }))
        #expect(group() == .waiting)
        try #require(test.github.held.first).respond(Data(#"{"data":{"markPullRequestReadyForReview":{"pullRequest":{"id":"PR_7","isDraft":false}}}}"#.utf8))
        #expect(await wait(until: { test.model.panel.toasts.contains { $0.message.hasSuffix("is ready for review") } }))
        #expect(group() == .waiting)
        #expect(test.model.errorMessage == nil)
        await test.model.inbox?.end()
    }

    @Test func a_graphql_field_error_is_a_failed_write_and_restores_the_timestamp() async throws {
        try await open()
        let before = try #require(requestedAt)
        model.nudge()
        #expect(await wait(until: { !github.held.isEmpty }))
        try #require(github.held.first).respond(Data(#"""
            {"data":{"requestReviews":null},"errors":[{"message":"Review denied","path":["requestReviews"],"extensions":{"type":"FORBIDDEN"}}]}
            """#.utf8))
        #expect(await wait(until: { model.errorMessage != nil }))
        #expect(requestedAt == before)
        #expect(model.errorMessage?.contains("Review denied") == true)
        await model.inbox?.end()
    }

    @Test func an_ended_session_ignores_a_late_mutation_response() async throws {
        try await open()
        let session = try #require(model.inbox)
        var wrote = false
        session.onWrite = { _ in wrote = true }
        model.nudge()
        #expect(await wait(until: { !github.held.isEmpty }))
        let pending = try #require(github.held.first)
        await session.end()
        #expect(environment.ended)
        pending.respond(Self.answered)
        #expect(await wait(until: { github.held.isEmpty }))
        // Give the caller its turn after the transport completes.
        try await Task.sleep(for: .milliseconds(50))
        #expect(!wrote)
        #expect(session.myPullRequestNodes.isEmpty)
        #expect(session.errorMessage == nil)
    }
}
