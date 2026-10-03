import Baton
import CatonCore
import SwiftUI

/// The operations the subject store owns rather than a view. The compiler
/// finds GraphQL by its marker attribute on a property, so they are declared
/// here; this type is never instantiated.
///
/// A notification names its subject by repository and number, not by GraphQL
/// id, so the first fetch of each subject is one request through
/// `repository(owner:name:)`. Once the id is known, refreshes go through
/// `nodes(ids:)` in batches, and both paths write the same records.
@MainActor
struct SubjectDocuments {
    @Query("""
        query PullRequestSubjectQuery($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              id
              ...PullRequestFacts_pullRequest
              ...PullRequestIcon_pullRequest
              ...PullRequestSignals_pullRequest
            }
          }
        }
        """)
    var pullRequest: PullRequestSubjectQuery

    @Query("""
        query IssueSubjectQuery($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            issue(number: $number) {
              id
              ...IssueFacts_issue
              ...IssueIcon_issue
              ...IssueSignals_issue
            }
          }
        }
        """)
    var issue: IssueSubjectQuery

    @Query("""
        query PullRequestRefreshQuery($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on PullRequest {
              id
              ...PullRequestFacts_pullRequest @alias
              ...PullRequestIcon_pullRequest @alias
              ...PullRequestSignals_pullRequest @alias
            }
          }
        }
        """)
    var pullRequests: PullRequestRefreshQuery

    /// Open pull requests that request the viewer by name. GitHub sometimes
    /// requests a review without a notification; these fill Needs me anyway.
    @Query("""
        query ReviewRequestsQuery {
          search(query: "is:pr is:open archived:false user-review-requested:@me", type: ISSUE, first: 50) {
            nodes {
              ... on PullRequest {
                id
                number
                title
                url
                updatedAt
                repository { name owner { login } }
                ...PullRequestFacts_pullRequest @alias
                ...PullRequestIcon_pullRequest @alias
                ...PullRequestSignals_pullRequest @alias
              }
            }
          }
        }
        """)
    var reviewRequests: ReviewRequestsQuery

    @Query("""
        query IssueRefreshQuery($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on Issue {
              id
              ...IssueFacts_issue @alias
              ...IssueIcon_issue @alias
              ...IssueSignals_issue @alias
            }
          }
        }
        """)
    var issues: IssueRefreshQuery
}

/// What classification reads from a pull request.
@MainActor
struct PullRequestFactsReader {
    @Fragment("""
        fragment PullRequestFacts_pullRequest on PullRequest {
          id
          state
          isDraft
          isInMergeQueue
          reviewDecision
          viewerDidAuthor
          author { login url avatarUrl }
          statusCheckRollup { state }
          viewerLatestReview { state }
          comments(last: 1) { nodes { author { login url } } }
          viewerLatestReviewRequest {
            requestedReviewer {
              ... on User { id }
              ... on Team { id }
            }
          }
          reviewRequests(first: 50) {
            nodes {
              requestedReviewer {
                ... on User { id }
                ... on Team { id }
              }
            }
          }
        }
        """)
    var pullRequest: PullRequestFacts_pullRequest

    /// The facts, with review requests resolved against the viewer: a pending
    /// request naming the viewer is theirs; otherwise a pending request for the
    /// team that last requested them is their team's.
    func facts(viewerID: String) -> SubjectFacts {
        let pending = pullRequest.reviewRequests?.nodes.map { Array($0) } ?? []
        let pendingUsers = Set(pending.compactMap { $0.requestedReviewer?.asUser?.id })
        let pendingTeams = Set(pending.compactMap { $0.requestedReviewer?.asTeam?.id })
        var request: SubjectFacts.ReviewRequest?
        if pendingUsers.contains(viewerID) {
            request = .you
        } else if let team = pullRequest.viewerLatestReviewRequest?.requestedReviewer?.asTeam?.id, pendingTeams.contains(team) {
            request = .team
        }
        return SubjectFacts(
            nodeID: pullRequest.id,
            state: SubjectFacts.State(graphQL: pullRequest.state),
            isDraft: pullRequest.isDraft,
            isInMergeQueue: pullRequest.isInMergeQueue,
            reviewDecision: pullRequest.reviewDecision.flatMap(SubjectFacts.ReviewDecision.init(graphQL:)),
            checks: pullRequest.statusCheckRollup.flatMap { SubjectFacts.Checks(graphQL: $0.state) },
            author: pullRequest.author.map { SubjectActor(login: $0.login, isApp: $0.url.contains("/apps/"), avatarURL: URL(string: $0.avatarUrl)) },
            viewerDidAuthor: pullRequest.viewerDidAuthor,
            pendingReviewRequest: request,
            viewerLatestReview: pullRequest.viewerLatestReview.flatMap { SubjectFacts.ReviewState(graphQL: $0.state) },
            latestCommenter: pullRequest.comments.nodes?.last?.author.map { SubjectActor(login: $0.login, isApp: $0.url.contains("/apps/")) }
        )
    }
}

/// What classification reads from an issue.
@MainActor
struct IssueFactsReader {
    @Fragment("""
        fragment IssueFacts_issue on Issue {
          id
          state
          stateReason
          viewerDidAuthor
          author { login url avatarUrl }
          comments(last: 1) { nodes { author { login url } } }
        }
        """)
    var issue: IssueFacts_issue

    func facts() -> SubjectFacts {
        SubjectFacts(
            nodeID: issue.id,
            state: issue.state == "OPEN" ? .open : .closed,
            closedReason: issue.stateReason.flatMap(SubjectFacts.ClosedReason.init(graphQL:)),
            author: issue.author.map { SubjectActor(login: $0.login, isApp: $0.url.contains("/apps/"), avatarURL: URL(string: $0.avatarUrl)) },
            viewerDidAuthor: issue.viewerDidAuthor,
            latestCommenter: issue.comments.nodes?.last?.author.map { SubjectActor(login: $0.login, isApp: $0.url.contains("/apps/")) }
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
