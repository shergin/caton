import Foundation

/// Why GitHub delivered a notification, as the REST API spells it.
public enum Reason: String, Codable, Sendable, CaseIterable {
    case approvalRequested = "approval_requested"
    case assign
    case author
    case ciActivity = "ci_activity"
    case comment
    case invitation
    case manual
    case memberFeatureRequested = "member_feature_requested"
    case mention
    case reviewRequested = "review_requested"
    case securityAdvisoryCredit = "security_advisory_credit"
    case securityAlert = "security_alert"
    case stateChange = "state_change"
    case subscribed
    case teamMention = "team_mention"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Reason(rawValue: raw) ?? .unknown
    }
}

/// What a notification thread is about.
public enum SubjectKind: String, Codable, Sendable {
    case pullRequest
    case issue
    case release
    case discussion
    case commit
    case checkSuite
    case workflowRun
    case securityAlert
    case invitation
    case other

    /// Maps the REST `subject.type` string.
    public init(restType: String) {
        switch restType {
        case "PullRequest": self = .pullRequest
        case "Issue": self = .issue
        case "Release": self = .release
        case "Discussion": self = .discussion
        case "Commit": self = .commit
        case "CheckSuite": self = .checkSuite
        case "WorkflowRun": self = .workflowRun
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread", "RepositoryAdvisory", "SecurityAdvisory":
            self = .securityAlert
        case "RepositoryInvitation": self = .invitation
        default: self = .other
        }
    }

    /// Whether the subject can be enriched with pull request or issue state.
    public var isIssueOrPullRequest: Bool { self == .pullRequest || self == .issue }
}

/// An `owner/name` pair.
public struct RepositoryName: Hashable, Codable, Sendable, Comparable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var fullName: String { "\(owner)/\(name)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.fullName.lowercased() < rhs.fullName.lowercased() }
}

/// One GitHub notification thread, as the REST feed last described it.
public struct NotificationThread: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var repository: RepositoryName
    public var kind: SubjectKind
    /// The issue or pull request number, when the subject has one.
    public var number: Int?
    public var title: String
    public var reason: Reason
    public var isUnread: Bool
    public var updatedAt: Date
    public var lastReadAt: Date?
    public var webURL: URL

    public init(
        id: String,
        repository: RepositoryName,
        kind: SubjectKind,
        number: Int?,
        title: String,
        reason: Reason,
        isUnread: Bool,
        updatedAt: Date,
        lastReadAt: Date? = nil,
        webURL: URL
    ) {
        self.id = id
        self.repository = repository
        self.kind = kind
        self.number = number
        self.title = title
        self.reason = reason
        self.isUnread = isUnread
        self.updatedAt = updatedAt
        self.lastReadAt = lastReadAt
        self.webURL = webURL
    }

    /// Whether GitHub's feed delivered the thread, so verbs can reach it.
    /// Threads Caton makes up (review requests found by search, reminders,
    /// the practice inbox) have ids no feed thread has.
    public var isFromFeed: Bool { !id.isEmpty && id.allSatisfy(\.isNumber) }

    /// `owner/name#123`, or the repository alone.
    public var reference: String {
        guard let number else { return repository.fullName }
        return "\(repository.fullName)#\(number)"
    }
}
