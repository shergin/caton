import Baton
import CatonCore
import Foundation

/// The classifier's reading of the facts fragments in `Subjects.graphql`:
/// plain `SubjectFacts`, so classification stays a pure function.
@MainActor
extension PullRequestFacts_pullRequest {
    /// The facts, with review requests resolved against the viewer: a pending
    /// request naming the viewer is theirs; otherwise a pending request for the
    /// team that last requested them is their team's.
    func facts(viewerID: String) -> SubjectFacts {
        let pending = reviewRequests?.nodes.map { Array($0) } ?? []
        let pendingUsers = Set(pending.compactMap { $0.requestedReviewer?.asUser?.id })
        let pendingTeams = Set(pending.compactMap { $0.requestedReviewer?.asTeam?.id })
        var request: SubjectFacts.ReviewRequest?
        if pendingUsers.contains(viewerID) {
            request = .you
        } else if let team = viewerLatestReviewRequest?.requestedReviewer?.asTeam?.id, pendingTeams.contains(team) {
            request = .team
        }
        return SubjectFacts(
            nodeID: id,
            state: SubjectFacts.State(graphQL: state),
            isDraft: isDraft,
            isInMergeQueue: isInMergeQueue,
            reviewDecision: reviewDecision.flatMap(SubjectFacts.ReviewDecision.init(graphQL:)),
            checks: statusCheckRollup.flatMap { SubjectFacts.Checks(graphQL: $0.state) },
            author: author.map { SubjectActor(login: $0.login, isApp: $0.url.contains("/apps/"), avatarURL: URL(string: $0.avatarUrl)) },
            viewerDidAuthor: viewerDidAuthor,
            pendingReviewRequest: request,
            viewerLatestReview: viewerLatestReview.flatMap { SubjectFacts.ReviewState(graphQL: $0.state) },
            latestCommenter: comments.nodes?.last?.author.map { SubjectActor(login: $0.login, isApp: $0.url.contains("/apps/")) },
            latestCommentAt: comments.nodes?.last.flatMap { try? Date($0.createdAt, strategy: .iso8601) }
        )
    }
}

@MainActor
extension IssueFacts_issue {
    func facts() -> SubjectFacts {
        SubjectFacts(
            nodeID: id,
            state: state == "OPEN" ? .open : .closed,
            closedReason: stateReason.flatMap(SubjectFacts.ClosedReason.init(graphQL:)),
            author: author.map { SubjectActor(login: $0.login, isApp: $0.url.contains("/apps/"), avatarURL: URL(string: $0.avatarUrl)) },
            viewerDidAuthor: viewerDidAuthor,
            latestCommenter: comments.nodes?.last?.author.map { SubjectActor(login: $0.login, isApp: $0.url.contains("/apps/")) },
            latestCommentAt: comments.nodes?.last.flatMap { try? Date($0.createdAt, strategy: .iso8601) }
        )
    }
}

extension SubjectFacts.State {
    init(graphQL: String) {
        switch graphQL {
        case "MERGED": self = .merged
        case "CLOSED": self = .closed
        default: self = .open
        }
    }
}

extension SubjectFacts.ReviewDecision {
    init?(graphQL: String) {
        switch graphQL {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: return nil
        }
    }
}

extension SubjectFacts.Checks {
    init?(graphQL: String) {
        switch graphQL {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        default: return nil
        }
    }
}

extension SubjectFacts.ReviewState {
    init?(graphQL: String) {
        switch graphQL {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "COMMENTED": self = .commented
        case "DISMISSED": self = .dismissed
        case "PENDING": self = .pending
        default: return nil
        }
    }
}

extension SubjectFacts.ClosedReason {
    init?(graphQL: String) {
        switch graphQL {
        case "COMPLETED": self = .completed
        case "NOT_PLANNED": self = .notPlanned
        case "DUPLICATE": self = .duplicate
        default: return nil
        }
    }
}
