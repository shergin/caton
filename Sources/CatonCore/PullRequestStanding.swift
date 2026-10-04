import Foundation

/// Where one of the viewer's own open pull requests stands, as plain data.
/// Built by the app from a GraphQL fragment; plain here so the reading of it
/// is a pure, tested function.
public struct PullRequestStatus: Hashable, Sendable {
    public enum Mergeable: String, Sendable {
        case mergeable
        case conflicting
        case unknown
    }

    /// Someone asked to review: a person (`alex`) or a team (`acme/web`).
    public struct Reviewer: Hashable, Sendable {
        public var name: String
        public var isTeam: Bool
        /// An app that reviews, such as Copilot's code review.
        public var isBot: Bool
        /// The node id a review request names the reviewer by; none for a
        /// mannequin, which a request cannot name again.
        public var id: String?

        public init(name: String, isTeam: Bool = false, isBot: Bool = false, id: String? = nil) {
            self.name = name
            self.isTeam = isTeam
            self.isBot = isBot
            self.id = id
        }

        /// `@alex`, `@acme/web`.
        public var handle: String { "@" + name }
    }

    /// One reviewer's latest review.
    public struct Review: Hashable, Sendable {
        public var login: String
        public var state: SubjectFacts.ReviewState
        public var at: Date?
        /// The reviewer's user or bot id, to ask them again.
        public var userID: String?
        public var botID: String?

        public init(login: String, state: SubjectFacts.ReviewState, at: Date? = nil, userID: String? = nil, botID: String? = nil) {
            self.login = login
            self.state = state
            self.at = at
            self.userID = userID
            self.botID = botID
        }
    }

    /// Who wrote something, and when.
    public struct Comment: Hashable, Sendable {
        public var login: String
        public var at: Date

        public init(login: String, at: Date) {
            self.login = login
            self.at = at
        }
    }

    public var isDraft: Bool
    public var isInMergeQueue: Bool
    public var reviewDecision: SubjectFacts.ReviewDecision?
    public var mergeable: Mergeable
    public var checks: SubjectFacts.Checks?
    /// Review requests still open.
    public var pendingReviewers: [Reviewer]
    /// The latest review of each reviewer.
    public var latestReviews: [Review]
    /// When review was last requested, if ever.
    public var requestedAt: Date?
    public var createdAt: Date
    /// The latest comment, for telling whether someone answered.
    public var lastComment: Comment?

    public init(
        isDraft: Bool = false,
        isInMergeQueue: Bool = false,
        reviewDecision: SubjectFacts.ReviewDecision? = nil,
        mergeable: Mergeable = .unknown,
        checks: SubjectFacts.Checks? = nil,
        pendingReviewers: [Reviewer] = [],
        latestReviews: [Review] = [],
        requestedAt: Date? = nil,
        createdAt: Date,
        lastComment: Comment? = nil
    ) {
        self.isDraft = isDraft
        self.isInMergeQueue = isInMergeQueue
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.checks = checks
        self.pendingReviewers = pendingReviewers
        self.latestReviews = latestReviews
        self.requestedAt = requestedAt
        self.createdAt = createdAt
        self.lastComment = lastComment
    }

    /// Whom a nudge asks again: every reviewer still pending, and everyone
    /// whose latest review asked for changes or only commented. Those who
    /// approved are left alone, and so is the viewer.
    public func nudge(excluding viewer: String) -> Nudge {
        var nudge = Nudge()
        for reviewer in pendingReviewers {
            guard let id = reviewer.id else { continue }
            if reviewer.isTeam {
                nudge.teamIDs.append(id)
            } else if reviewer.isBot {
                nudge.botIDs.append(id)
            } else {
                nudge.userIDs.append(id)
            }
            nudge.names.append(reviewer.handle)
        }
        let pending = Set(pendingReviewers.map { $0.name.lowercased() })
        for review in latestReviews where review.state == .changesRequested || review.state == .commented {
            let login = review.login.lowercased()
            guard !pending.contains(login), login != viewer.lowercased() else { continue }
            if let id = review.userID, !nudge.userIDs.contains(id) {
                nudge.userIDs.append(id)
            } else if let id = review.botID, !nudge.botIDs.contains(id) {
                nudge.botIDs.append(id)
            } else {
                continue
            }
            nudge.names.append("@" + review.login)
        }
        return nudge
    }

    /// When someone other than the viewer last reviewed or commented: the
    /// answer a follow-up waits for.
    public func lastResponse(excluding viewer: String) -> Date? {
        let reviews = latestReviews.filter { $0.login.caseInsensitiveCompare(viewer) != .orderedSame }.compactMap(\.at)
        var answers = reviews
        if let lastComment, lastComment.login.caseInsensitiveCompare(viewer) != .orderedSame { answers.append(lastComment.at) }
        return answers.max()
    }
}

/// Whom to ask again for a review, by node id, and how to name them.
public struct Nudge: Hashable, Sendable {
    public var userIDs: [String] = []
    public var teamIDs: [String] = []
    public var botIDs: [String] = []
    /// `@alex`, `@acme/web`, in the order asked.
    public var names: [String] = []

    public init() {}

    public var isEmpty: Bool { userIDs.isEmpty && teamIDs.isEmpty && botIDs.isEmpty }

    /// "@alex and @acme/web".
    public var summary: String {
        switch names.count {
        case 0: "nobody"
        case 1: names[0]
        case 2: names.joined(separator: " and ")
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

/// Where a pull request stands, from the author's side: what it waits for.
public enum PullRequestStanding: Hashable, Sendable {
    case draft
    case inMergeQueue
    case conflicts
    case checksFailing
    case changesRequested(by: [String])
    case readyToMerge
    case approvedChecksRunning
    case waitingOnReview(from: [PullRequestStatus.Reviewer], since: Date)
    case noReviewer(since: Date)
    case checksRunning

    /// The groups My PRs shows, in order.
    public enum Group: Int, CaseIterable, Sendable, Comparable {
        /// It is the author's move: fix, address, merge.
        case yourMove
        /// It is someone else's move: review, CI, the merge queue.
        case waiting
        case drafts

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .yourMove: "Your move"
            case .waiting: "Waiting on others"
            case .drafts: "Drafts"
            }
        }
    }

    public var group: Group {
        switch self {
        case .draft: .drafts
        case .conflicts, .checksFailing, .changesRequested, .readyToMerge, .noReviewer: .yourMove
        case .inMergeQueue, .approvedChecksRunning, .waitingOnReview, .checksRunning: .waiting
        }
    }

    /// The line a row shows: "waiting on @alex · 3d".
    public func summary(now: Date) -> String {
        switch self {
        case .draft: "draft"
        case .inMergeQueue: "in the merge queue"
        case .conflicts: "has conflicts"
        case .checksFailing: "checks failing"
        case .changesRequested(let by): by.isEmpty ? "changes requested" : "changes requested by " + by.map { "@" + $0 }.joined(separator: ", ")
        case .readyToMerge: "approved, ready to merge"
        case .approvedChecksRunning: "approved, checks running"
        case .waitingOnReview(let reviewers, let since):
            "waiting on " + Self.list(reviewers.map(\.handle)) + " · " + Self.age(now.timeIntervalSince(since))
        case .noReviewer(let since): "no reviewer requested · " + Self.age(now.timeIntervalSince(since))
        case .checksRunning: "checks running"
        }
    }

    /// Reads a pull request's status, the most pressing first: a draft is a
    /// draft; then the merge queue; then what blocks a merge (conflicts,
    /// failing checks, requested changes); then approval; then whom it waits on.
    public static func of(_ status: PullRequestStatus) -> PullRequestStanding {
        if status.isDraft { return .draft }
        if status.isInMergeQueue { return .inMergeQueue }
        if status.mergeable == .conflicting { return .conflicts }
        if status.checks == .failure { return .checksFailing }
        if status.reviewDecision == .changesRequested {
            return .changesRequested(by: status.latestReviews.filter { $0.state == .changesRequested }.map(\.login))
        }
        let approved = status.reviewDecision == .approved
            || (status.reviewDecision == nil && status.latestReviews.contains { $0.state == .approved })
        if approved {
            return status.checks == .pending ? .approvedChecksRunning : .readyToMerge
        }
        if !status.pendingReviewers.isEmpty {
            return .waitingOnReview(from: status.pendingReviewers, since: status.requestedAt ?? status.createdAt)
        }
        if status.checks == .pending { return .checksRunning }
        return .noReviewer(since: status.createdAt)
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: "review"
        case 1, 2: names.joined(separator: " and ")
        default: "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    static func age(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3600: "\(max(1, Int(seconds / 60)))m"
        case ..<86400: "\(Int(seconds / 3600))h"
        default: "\(Int(seconds / 86400))d"
        }
    }
}

/// A reminder on one of the viewer's pull requests: come back at `until`
/// unless someone has answered (reviewed or commented) since it was set.
public struct FollowUp: Codable, Hashable, Sendable {
    public var until: Date
    /// The last answer from someone else when the reminder was set.
    public var answeredAt: Date?
    public var repository: RepositoryName
    public var number: Int
    public var title: String
    public var url: URL

    public init(until: Date, answeredAt: Date?, repository: RepositoryName, number: Int, title: String, url: URL) {
        self.until = until
        self.answeredAt = answeredAt
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
    }

    /// `owner/name#123`.
    public var reference: String { "\(repository.fullName)#\(number)" }

    public enum Outcome: Equatable, Sendable {
        /// Not yet time.
        case waiting
        /// Time, and no one answered: remind.
        case due
        /// Someone answered: the reminder has done its job.
        case answered
    }

    /// Whether to remind now, given the latest answer known. An unknown
    /// pull request (not loaded yet) is reminded about: a reminder is never
    /// lost for want of data.
    public func outcome(lastResponse: Date?, now: Date) -> Outcome {
        if let lastResponse, lastResponse > (answeredAt ?? .distantPast) { return .answered }
        return now >= until ? .due : .waiting
    }
}
