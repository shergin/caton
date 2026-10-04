import Foundation

/// The four mutually exclusive partitions of the inbox.
public enum Split: Int, CaseIterable, Codable, Sendable, Comparable {
    case needsMe
    case team
    case following
    case feed

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .needsMe: "Needs me"
        case .team: "Team"
        case .following: "Following"
        case .feed: "Feed"
        }
    }
}

/// The short ownership label a row carries.
public enum Badge: Hashable, Sendable {
    case reviewRequested
    case reviewYou
    case reviewTeam
    case reviewed
    case mentioned
    case teamMentioned
    case assigned
    case approvalRequested
    case securityAlert
    case invitation
    case yourPullRequest(YourPullRequest)
    case author
    case commented
    case manual
    case stateChanged
    case ciActivity
    case subscribed

    /// Why the viewer's own open pull request needs them.
    public enum YourPullRequest: Hashable, Sendable {
        case changesRequested
        case checksFailed
        case readyToMerge
    }

    public var title: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .reviewYou: "Review · you"
        case .reviewTeam: "Review · team"
        case .reviewed: "Reviewed"
        case .mentioned: "Mentioned"
        case .teamMentioned: "Team mentioned"
        case .assigned: "Assigned"
        case .approvalRequested: "Approval requested"
        case .securityAlert: "Security alert"
        case .invitation: "Invitation"
        case .yourPullRequest(.changesRequested): "Changes requested"
        case .yourPullRequest(.checksFailed): "Checks failed"
        case .yourPullRequest(.readyToMerge): "Ready to merge"
        case .author: "Author"
        case .commented: "Commented"
        case .manual: "Subscribed"
        case .stateChanged: "State change"
        case .ciActivity: "CI activity"
        case .subscribed: "Watching"
        }
    }

    /// Whether the badge names a direct ask of the viewer.
    public var isDirect: Bool {
        switch self {
        case .reviewYou, .mentioned, .assigned, .approvalRequested, .securityAlert, .invitation, .yourPullRequest:
            true
        default:
            false
        }
    }
}

/// The default rules that clear or route threads without the user.
public enum Rule: String, Codable, Sendable, CaseIterable {
    /// A merged or closed subject outside Needs me is marked done.
    case mergedOrClosed
    /// A draft pull request that does not request the viewer goes to Feed.
    case drafts
    /// A pull request authored by a bot goes to Feed.
    case botPullRequests
    /// A thread in a locally muted repository is marked done.
    case mutedRepositories

    public var title: String {
        switch self {
        case .mergedOrClosed: "Merged or closed"
        case .drafts: "Drafts"
        case .botPullRequests: "Bot pull requests"
        case .mutedRepositories: "Muted repositories"
        }
    }
}

/// What the classifier decided about one thread.
public struct Classification: Hashable, Sendable {
    public var split: Split
    public var badge: Badge
    /// The rule that moved the thread to its split, if one did.
    public var routedBy: Rule?
    /// The rule that clears the thread, if one does.
    public var clearedBy: Rule?
    public var actorKind: ActorKind?
    /// Why the thread is where it is, in a sentence, for "Why is this here?".
    public var because: String

    public init(split: Split, badge: Badge, routedBy: Rule? = nil, clearedBy: Rule? = nil, actorKind: ActorKind? = nil, because: String = "") {
        self.split = split
        self.badge = badge
        self.routedBy = routedBy
        self.clearedBy = clearedBy
        self.actorKind = actorKind
        self.because = because
    }
}

/// The user's switches for classification.
public struct ClassifierSettings: Codable, Hashable, Sendable {
    public var enabledRules: Set<Rule>
    /// Repositories muted locally, as `owner/name`, compared case-insensitively.
    public var mutedRepositories: Set<String>
    /// Logins of AI reviewers, lowercased.
    public var aiReviewerLogins: Set<String>
    /// Logins of coding agents that open pull requests, lowercased.
    public var agentLogins: Set<String>
    /// Ordinary accounts the user knows are bots, lowercased.
    public var botLogins: Set<String>

    public init(
        enabledRules: Set<Rule> = Set(Rule.allCases),
        mutedRepositories: Set<String> = [],
        aiReviewerLogins: Set<String> = ClassifierSettings.defaultAIReviewers,
        agentLogins: Set<String> = ClassifierSettings.defaultAgents,
        botLogins: Set<String> = []
    ) {
        self.enabledRules = enabledRules
        self.mutedRepositories = mutedRepositories
        self.aiReviewerLogins = aiReviewerLogins
        self.agentLogins = agentLogins
        self.botLogins = botLogins
    }

    private enum CodingKeys: String, CodingKey {
        case enabledRules, mutedRepositories, aiReviewerLogins, agentLogins, botLogins
    }

    /// Reads settings saved by earlier versions: a missing key takes its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledRules = try container.decodeIfPresent(Set<Rule>.self, forKey: .enabledRules) ?? Set(Rule.allCases)
        mutedRepositories = try container.decodeIfPresent(Set<String>.self, forKey: .mutedRepositories) ?? []
        aiReviewerLogins = try container.decodeIfPresent(Set<String>.self, forKey: .aiReviewerLogins) ?? Self.defaultAIReviewers
        agentLogins = try container.decodeIfPresent(Set<String>.self, forKey: .agentLogins) ?? Self.defaultAgents
        botLogins = try container.decodeIfPresent(Set<String>.self, forKey: .botLogins) ?? []
    }

    public static let defaultAIReviewers: Set<String> = [
        "copilot-pull-request-reviewer",
        "coderabbitai",
        "gemini-code-assist",
        "greptile-apps",
        "sourcery-ai",
        "ellipsis-dev",
        "graphite-app",
        "cursor",
    ]

    public static let defaultAgents: Set<String> = [
        "copilot",
        "copilot-swe-agent",
        "devin-ai-integration",
        "openai-codex",
        "claude",
    ]

    public func isMuted(_ repository: RepositoryName) -> Bool {
        mutedRepositories.contains(repository.fullName.lowercased())
    }

    public func kind(of actor: SubjectActor) -> ActorKind {
        let login = actor.login.lowercased()
        if agentLogins.contains(login) { return .agent }
        if aiReviewerLogins.contains(login) { return .aiReviewer }
        if actor.isApp || botLogins.contains(login) || Self.looksLikeBot(login) { return .bot }
        return .human
    }

    /// Machine accounts that are ordinary users, named the way projects name
    /// them: `react-native-bot`, `k8s-ci-robot`, `stale[bot]`.
    static func looksLikeBot(_ login: String) -> Bool {
        ["[bot]", "-bot", "_bot", "robot"].contains { login.hasSuffix($0) }
    }
}

/// Decides each thread's split, badge and rule actions. Pure: the same
/// thread, facts and settings always give the same classification.
public enum Classifier {
    public static func classify(_ thread: NotificationThread, facts: SubjectFacts?, settings: ClassifierSettings) -> Classification {
        let actorKind = facts?.author.map(settings.kind(of:))
        var (split, badge, because) = baseSplit(thread, facts: facts, settings: settings)

        // Rules never touch Needs me: a direct ask in a muted repository still arrives.
        if split != .needsMe, settings.enabledRules.contains(.mutedRepositories), settings.isMuted(thread.repository) {
            return Classification(split: .feed, badge: badge, clearedBy: .mutedRepositories, actorKind: actorKind, because: "You muted \(thread.repository.fullName).")
        }

        var routedBy: Rule?
        if split != .needsMe, thread.kind == .pullRequest, let facts {
            if settings.enabledRules.contains(.botPullRequests), actorKind == .bot {
                split = .feed
                routedBy = .botPullRequests
                because = "A bot (\(facts.author?.login ?? "unknown")) opened it, so the Bot pull requests rule moved it to Feed."
            } else if settings.enabledRules.contains(.drafts), facts.isDraft, facts.state == .open, split != .feed {
                split = .feed
                routedBy = .drafts
                because = "It is a draft that does not ask for your review, so the Drafts rule moved it to Feed."
            }
        }

        var clearedBy: Rule?
        if split != .needsMe, settings.enabledRules.contains(.mergedOrClosed), let facts, facts.state != .open {
            clearedBy = .mergedOrClosed
        }

        return Classification(split: split, badge: badge, routedBy: routedBy, clearedBy: clearedBy, actorKind: actorKind, because: because)
    }

    /// The split before rules, and why: state first, then the notification's reason.
    static func baseSplit(_ thread: NotificationThread, facts: SubjectFacts?, settings: ClassifierSettings) -> (Split, Badge, String) {
        // A pending request that names the viewer needs them whatever the reason says.
        if thread.kind == .pullRequest, let facts, facts.state == .open {
            if facts.pendingReviewRequest == .you {
                return (.needsMe, .reviewYou, "Your review is requested by name, and you have not given it since.")
            }
            if facts.viewerDidAuthor, let status = yourPullRequestStatus(facts) {
                let why = switch status {
                case .changesRequested: "It is your pull request, and a reviewer requested changes."
                case .checksFailed: "It is your pull request, and its checks are failing."
                case .readyToMerge: "It is your pull request, approved with passing checks: ready to merge."
                }
                return (.needsMe, .yourPullRequest(status), why)
            }
        }

        // A closed subject whose last word came from a bot: the reason is a
        // leftover from earlier activity, not a new ask.
        if let facts, facts.state != .open, let commenter = facts.latestCommenter, settings.kind(of: commenter) != .human,
           thread.reason == .mention || thread.reason == .assign || thread.reason == .teamMention {
            return (.following, thread.reason == .assign ? .assigned : .mentioned,
                    "GitHub still says \(thread.reason.rawValue), but it is closed and the last comment came from \(commenter.login), so the ask is old news.")
        }

        switch thread.reason {
        case .mention:
            return (.needsMe, .mentioned, "You were @mentioned.")
        case .assign:
            return (.needsMe, .assigned, "You are assigned.")
        case .approvalRequested:
            return (.needsMe, .approvalRequested, "A deployment is waiting for your approval.")
        case .securityAlert:
            return (.needsMe, .securityAlert, "A security alert on a repository you can fix.")
        case .invitation:
            return (.needsMe, .invitation, "You were invited to a repository.")
        case .reviewRequested:
            // Until the pull request is known, a possible direct ask is never hidden.
            guard let facts else {
                return (.needsMe, .reviewRequested, "A review was requested. Until the pull request loads, Caton can't tell you from your team, so it stays here.")
            }
            if facts.state == .open, facts.pendingReviewRequest == .team {
                return (.team, .reviewTeam, "Your review was requested through a team, not by name.")
            }
            return (.following, .reviewed, "You were asked to review, and you already have or the request was withdrawn.")
        case .teamMention:
            return (.team, .teamMentioned, "A team you are on was mentioned.")
        case .author:
            return (.following, .author, "You opened it; nothing is asked of you right now.")
        case .comment:
            return (.following, .commented, "You commented on it; nothing is asked of you.")
        case .manual:
            return (.following, .manual, "You subscribed to it.")
        case .stateChange:
            return (.following, .stateChanged, "You opened or closed it.")
        case .ciActivity:
            return (.feed, .ciActivity, "A workflow run you triggered finished.")
        case .subscribed, .memberFeatureRequested, .securityAdvisoryCredit, .unknown:
            return (.feed, .subscribed, "You watch \(thread.repository.fullName).")
        }
    }

    /// Why the viewer's own open, non-draft pull request is back with them.
    static func yourPullRequestStatus(_ facts: SubjectFacts) -> Badge.YourPullRequest? {
        guard !facts.isDraft else { return nil }
        if facts.reviewDecision == .changesRequested { return .changesRequested }
        if facts.checks == .failure { return .checksFailed }
        if facts.reviewDecision == .approved, facts.checks != .pending, !facts.isInMergeQueue { return .readyToMerge }
        return nil
    }
}
