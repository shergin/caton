import Baton
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
    /// GitHub, played by a script: My PRs answers at once, the review
    /// request search finds nothing, and a mutation is recorded and waits
    /// until the test says how GitHub answers it.
    actor GitHub: Transport {
        private(set) var mutations: [Request] = []
        private var answer: CheckedContinuation<Data, any Error>?
        let myPullRequests: Data

        init(myPullRequests: Data = ImageTests.response) {
            self.myPullRequests = myPullRequests
        }

        nonisolated func execute(_ request: Request) async throws -> Data {
            if request.operationName == "ReviewRequestsQuery" { return Data(#"{"data":{"search":{"nodes":[]}}}"#.utf8) }
            guard request.operationName.hasSuffix("Mutation") else { return myPullRequests }
            return try await withCheckedThrowingContinuation { continuation in
                Task { await self.hold(request, continuation) }
            }
        }

        private func hold(_ request: Request, _ continuation: CheckedContinuation<Data, any Error>) {
            mutations.append(request)
            answer = continuation
        }

        func reply(_ data: Data) {
            answer?.resume(returning: data)
            answer = nil
        }

        func refuse() {
            answer?.resume(throwing: TransportError(statusCode: 422, body: "Review cannot be requested from pull request author."))
            answer = nil
        }
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

    let github: GitHub
    let model: AppModel
    let environment: Baton.Environment

    init() {
        self.init(github: GitHub())
    }

    init(github: GitHub) {
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

    func until(_ condition: () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func undo_inside_the_window_sends_nothing() async throws {
        try await open()
        model.nudge()
        #expect(model.pendingWriteNote(for: "PR_7") == "asking again…")
        model.undo()
        #expect(model.inbox!.pendingWrites.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await github.mutations.isEmpty)
    }

    @Test func a_nudge_shows_at_once_then_takes_githubs_answer() async throws {
        try await open()
        let before = try #require(requestedAt)
        model.nudge()
        await until { await !github.mutations.isEmpty }
        let request = try #require(await github.mutations.first)
        #expect(request.operationName == "NudgeReviewersMutation")
        #expect(request.variables.json.contains("U_alex") && request.variables.json.contains("T_web"))

        // Sent, not answered: the optimistic response is what the row reads.
        let optimistic = try #require(requestedAt)
        #expect(optimistic > before)
        #expect(Date.now.timeIntervalSince(optimistic) < 60)

        await github.reply(Self.answered)
        await until { requestedAt == (try? Date("2026-10-04T08:00:00Z", strategy: .iso8601)) }
        #expect(requestedAt == (try? Date("2026-10-04T08:00:00Z", strategy: .iso8601)))
        #expect(model.errorMessage == nil)
    }

    @Test func a_refused_nudge_is_taken_back_and_said() async throws {
        try await open()
        let before = try #require(requestedAt)
        model.nudge()
        await until { await !github.mutations.isEmpty }
        #expect(try #require(requestedAt) > before)
        await github.refuse()
        await until { model.errorMessage != nil }
        #expect(requestedAt == before)
        #expect(model.errorMessage?.hasPrefix("Couldn't change acme/web#7") == true)
    }

    @Test func ready_for_review_moves_the_draft_out_of_drafts_at_once() async throws {
        let draft = Data(String(decoding: ImageTests.response, as: UTF8.self).replacingOccurrences(of: #""isDraft":false"#, with: #""isDraft":true"#).utf8)
        let test = WriteTests(github: GitHub(myPullRequests: draft))
        try await test.open()
        func group() -> PullRequestStanding.Group? {
            test.model.myPullRequestNode("PR_7").map { PullRequestStanding.of(MyPullRequests.status($0.pullRequestStanding)).group }
        }
        #expect(group() == .drafts)
        test.model.nudge()
        #expect(test.model.inbox!.pendingWrites.isEmpty)
        test.model.markReadyForReview()
        await test.until { await !test.github.mutations.isEmpty }
        #expect(group() == .waiting)
        await test.github.reply(Data(#"{"data":{"markPullRequestReadyForReview":{"pullRequest":{"id":"PR_7","isDraft":false}}}}"#.utf8))
        await test.until { test.model.panel.toasts.contains { $0.message.hasSuffix("is ready for review") } }
        #expect(group() == .waiting)
        #expect(test.model.errorMessage == nil)
    }
}
