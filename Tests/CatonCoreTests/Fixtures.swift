import Foundation
@testable import CatonCore

let reference = Date(timeIntervalSince1970: 1_790_000_000)

func makeThread(
    id: String = "1",
    repository: String = "acme/web",
    kind: SubjectKind = .pullRequest,
    number: Int? = 42,
    reason: Reason = .subscribed,
    unread: Bool = true,
    updatedAt: Date = reference
) -> NotificationThread {
    let parts = repository.split(separator: "/").map(String.init)
    return NotificationThread(
        id: id,
        repository: RepositoryName(owner: parts[0], name: parts[1]),
        kind: kind,
        number: number,
        title: "Thread \(id)",
        reason: reason,
        isUnread: unread,
        updatedAt: updatedAt,
        webURL: URL(string: "https://github.com/\(repository)/pull/\(number ?? 0)")!
    )
}

func makeFacts(
    state: SubjectFacts.State = .open,
    isDraft: Bool = false,
    reviewDecision: SubjectFacts.ReviewDecision? = nil,
    checks: SubjectFacts.Checks? = nil,
    author: String = "octocat",
    authorIsApp: Bool = false,
    viewerDidAuthor: Bool = false,
    pendingReviewRequest: SubjectFacts.ReviewRequest? = nil
) -> SubjectFacts {
    SubjectFacts(
        nodeID: "PR_1",
        state: state,
        isDraft: isDraft,
        reviewDecision: reviewDecision,
        checks: checks,
        author: SubjectActor(login: author, isApp: authorIsApp),
        viewerDidAuthor: viewerDidAuthor,
        pendingReviewRequest: pendingReviewRequest
    )
}

/// Answers each request with the next canned response, and records requests.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: Response = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? Response(status: 500, body: "no stub") : responses.removeFirst()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (Data(response.body.utf8), http)
    }

    var recorded: [URLRequest] { lock.withLock { requests } }
}

func notificationJSON(id: String, type: String = "PullRequest", number: Int = 42, reason: String = "subscribed", unread: Bool = true, updatedAt: String = "2026-10-01T10:00:00Z") -> String {
    """
    {"id":"\(id)","unread":\(unread),"reason":"\(reason)","updated_at":"\(updatedAt)","last_read_at":null,
     "subject":{"title":"Title \(id)","url":"https://api.github.com/repos/acme/web/pulls/\(number)","latest_comment_url":null,"type":"\(type)"},
     "repository":{"name":"web","full_name":"acme/web","owner":{"login":"acme"},"html_url":"https://github.com/acme/web"}}
    """
}
