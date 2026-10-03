import Foundation

/// The panel's filter: free words plus GitHub-style qualifiers, each
/// negatable with a leading `-`. Words match the title or `owner/name#123`;
/// every term must hold.
///
///     repo:web -org:acme reason:review is:pr -is:draft author:octocat ci:failing
public struct SearchQuery: Equatable, Sendable {
    public enum Term: Equatable, Sendable {
        case text(String)
        case repository(String)
        case organization(String)
        case reason(Reason)
        case kind(SubjectKind)
        case draft
        case unread
        case state(SubjectFacts.State)
        case bot
        case author(String)
        case checks(SubjectFacts.Checks)
    }

    public struct Clause: Equatable, Sendable {
        public let term: Term
        public let negated: Bool
    }

    public let clauses: [Clause]

    public var isEmpty: Bool { clauses.isEmpty }

    public init(_ text: String) {
        clauses = Self.tokens(text).compactMap(Self.clause)
    }

    public func matches(_ item: InboxItem, facts: SubjectFacts?) -> Bool {
        clauses.allSatisfy { clause in
            Self.holds(clause.term, item: item, facts: facts) != clause.negated
        }
    }

    // MARK: Parsing

    /// Splits on whitespace, keeping double-quoted phrases whole.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func clause(_ token: String) -> Clause? {
        let negated = token.hasPrefix("-") && token.count > 1
        let body = negated ? String(token.dropFirst()) : token
        guard let colon = body.firstIndex(of: ":") else {
            return Clause(term: .text(token), negated: false)
        }
        let key = body[..<colon].lowercased()
        let value = String(body[body.index(after: colon)...])
        guard !value.isEmpty, let term = term(key: key, value: value) else {
            return Clause(term: .text(token), negated: false)
        }
        return Clause(term: term, negated: negated)
    }

    static func term(key: String, value: String) -> Term? {
        let lowered = value.lowercased()
        switch key {
        case "repo": return .repository(lowered)
        case "org", "owner", "user": return .organization(lowered)
        case "author": return .author(lowered)
        case "reason": return reasonAliases[lowered].map(Term.reason) ?? Reason(rawValue: lowered).map(Term.reason)
        case "ci", "checks":
            switch lowered {
            case "failing", "failure", "failed": return .checks(.failure)
            case "passing", "success", "green": return .checks(.success)
            case "pending", "running": return .checks(.pending)
            default: return nil
            }
        case "is", "state":
            switch lowered {
            case "pr", "pull", "pullrequest": return .kind(.pullRequest)
            case "issue": return .kind(.issue)
            case "release": return .kind(.release)
            case "discussion": return .kind(.discussion)
            case "draft": return .draft
            case "unread": return .unread
            case "read": return nil
            case "open": return .state(.open)
            case "closed": return .state(.closed)
            case "merged": return .state(.merged)
            case "bot": return .bot
            default: return nil
            }
        default:
            return nil
        }
    }

    static let reasonAliases: [String: Reason] = [
        "review": .reviewRequested,
        "review-requested": .reviewRequested,
        "mentioned": .mention,
        "assigned": .assign,
        "team": .teamMention,
        "team-mention": .teamMention,
        "ci": .ciActivity,
        "watching": .subscribed,
        "state-change": .stateChange,
        "approval": .approvalRequested,
        "security": .securityAlert,
    ]

    // MARK: Matching

    static func holds(_ term: Term, item: InboxItem, facts: SubjectFacts?) -> Bool {
        let thread = item.thread
        switch term {
        case .text(let text):
            return thread.title.localizedStandardContains(text) || thread.reference.localizedStandardContains(text)
        case .repository(let name):
            let full = thread.repository.fullName.lowercased()
            return full == name || thread.repository.name.lowercased() == name
        case .organization(let owner):
            return thread.repository.owner.lowercased() == owner
        case .reason(let reason):
            return thread.reason == reason
        case .kind(let kind):
            return thread.kind == kind
        case .draft:
            return facts?.isDraft ?? false
        case .unread:
            return item.isUnread
        case .state(let state):
            return facts?.state == state
        case .bot:
            return item.classification.actorKind == .bot
        case .author(let login):
            return facts?.author?.login.lowercased() == login
        case .checks(let checks):
            return facts?.checks == checks
        }
    }
}
