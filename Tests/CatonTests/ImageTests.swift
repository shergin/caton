import Baton
import CatonCore
import Foundation
import Testing
@testable import Caton

/// My PRs renders from Baton's image at launch: a second environment, with
/// no network, reads the screen's query back from the file the first one
/// wrote. The reviewer union selects each member's own fields (`login`
/// through the `Actor` interface, a team's `slug`), which the image can only
/// satisfy when the plan keeps type conditions.
@MainActor
struct ImageTests {
    struct Canned: Transport {
        let response: Data
        func execute(_ request: Request) async throws -> Data { response }
    }

    struct Offline: Transport {
        func execute(_ request: Request) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    /// One of the viewer's pull requests, waiting on a person and a team.
    nonisolated static let response = Data(#"""
        {"data":{"viewer":{"login":"me","id":"U_me","pullRequests":{"totalCount":1,"edges":[{"cursor":"c1","node":{
          "__typename":"PullRequest","id":"PR_7","url":"https://github.com/acme/web/pull/7",
          "repository":{"isArchived":false,"nameWithOwner":"acme/web","id":"R_web"},
          "title":"Add caching","number":7,"state":"OPEN","isDraft":false,"isInMergeQueue":false,
          "reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","createdAt":"2026-09-28T10:00:00Z",
          "statusCheckRollup":{"state":"SUCCESS","id":"SC_7"},
          "reviewRequests":{"nodes":[
            {"id":"RR_1","requestedReviewer":{"__typename":"User","__isActor":"User","login":"alex","__isNode":"User","id":"U_alex"}},
            {"id":"RR_2","requestedReviewer":{"__typename":"Team","slug":"web","organization":{"login":"acme","id":"O_acme"},"__isNode":"Team","id":"T_web"}}
          ]},
          "latestReviews":{"nodes":[]},
          "comments":{"nodes":[]},
          "timelineItems":{"nodes":[{"__typename":"ReviewRequestedEvent","createdAt":"2026-10-01T10:00:00Z","__isNode":"ReviewRequestedEvent","id":"RRE_1"}]}
        }}],"pageInfo":{"endCursor":"c1","hasNextPage":false}}}}}
        """#.utf8)

    @Test func my_pull_requests_render_from_the_image_with_every_kind_of_reviewer() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "caton-image-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = Persistence(url: url)
        let online = Baton.Environment(transport: Canned(response: Self.response), store: Store(persistence: written))
        try await online.fetch(MyPullRequestsQuery())
        await written.close()

        let offline = Baton.Environment(transport: Offline(), store: Store(persistence: Persistence(url: url)))
        let handle = offline.handle(for: MyPullRequestsQuery(), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else {
            Issue.record("My PRs was not ready from the image: \(handle.phase)")
            return
        }
        let node = try #require(data.viewer.myPullRequestList.pullRequests.nodes.first)
        let status = MyPullRequests.status(node.pullRequestStanding)
        #expect(status.pendingReviewers == [.init(name: "alex", id: "U_alex"), .init(name: "acme/web", isTeam: true, id: "T_web")])
        #expect(PullRequestStanding.of(status).summary(now: status.requestedAt!.addingTimeInterval(2 * 86400)) == "waiting on @alex and @acme/web · 2d")
    }
}
