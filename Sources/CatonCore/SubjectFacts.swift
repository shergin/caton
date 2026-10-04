import Foundation

/// The live state of a notification's pull request or issue, as far as
/// classification needs it. Built from GraphQL by the app; plain data here so
/// the classifier stays a pure function.
public struct SubjectFacts: Hashable, Sendable {
    public enum State: String, Sendable {
        case open
        case closed
        case merged
    }

    public enum ClosedReason: String, Sendable {
        case completed
        case notPlanned
        case duplicate
    }

    public enum ReviewDecision: String, Sendable {
        case approved
        case changesRequested
        case reviewRequired
    }

    public enum Checks: String, Sendable {
        case success
        case failure
        case pending
    }

    /// Who a pending review request names, as seen by the viewer.
    public enum ReviewRequest: Hashable, Sendable {
        /// The viewer, by name.
        case you
        /// A team the viewer belongs to.
        case team
    }

    public enum ReviewState: String, Sendable {
        case approved
        case changesRequested
        case commented
        case dismissed
        case pending
    }

    public var nodeID: String
    public var state: State
    public var closedReason: ClosedReason?
    public var isDraft: Bool
    public var isInMergeQueue: Bool
    public var reviewDecision: ReviewDecision?
    public var checks: Checks?
    public var author: SubjectActor?
    public var viewerDidAuthor: Bool
    public var pendingReviewRequest: ReviewRequest?
    public var viewerLatestReview: ReviewState?
    /// Who wrote the latest comment. A thread's reason stays at its first
    /// value, so an old mention can outlive the conversation it came from.
    public var latestCommenter: SubjectActor?
    /// When the latest comment was written, to tell whether it is news.
    public var latestCommentAt: Date?

    public init(
        nodeID: String,
        state: State,
        closedReason: ClosedReason? = nil,
        isDraft: Bool = false,
        isInMergeQueue: Bool = false,
        reviewDecision: ReviewDecision? = nil,
        checks: Checks? = nil,
        author: SubjectActor? = nil,
        viewerDidAuthor: Bool = false,
        pendingReviewRequest: ReviewRequest? = nil,
        viewerLatestReview: ReviewState? = nil,
        latestCommenter: SubjectActor? = nil,
        latestCommentAt: Date? = nil
    ) {
        self.nodeID = nodeID
        self.state = state
        self.closedReason = closedReason
        self.isDraft = isDraft
        self.isInMergeQueue = isInMergeQueue
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.author = author
        self.viewerDidAuthor = viewerDidAuthor
        self.pendingReviewRequest = pendingReviewRequest
        self.viewerLatestReview = viewerLatestReview
        self.latestCommenter = latestCommenter
        self.latestCommentAt = latestCommentAt
    }
}

/// The author of a subject.
public struct SubjectActor: Hashable, Sendable {
    public var login: String
    /// Whether the actor is a GitHub App (its profile lives under `/apps/`).
    public var isApp: Bool
    public var avatarURL: URL?

    public init(login: String, isApp: Bool, avatarURL: URL? = nil) {
        self.login = login
        self.isApp = isApp
        self.avatarURL = avatarURL
    }
}

/// What kind of party authored a subject.
public enum ActorKind: String, Codable, Sendable {
    case human
    case bot
    case aiReviewer
    case agent
}
