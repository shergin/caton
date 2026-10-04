import Foundation

/// A made-up inbox for learning the keys: every split, a returning thread,
/// a bot's bundle and a busy repository, a draft and a merged pull request
/// for the rules. Nothing in it exists on GitHub.
public enum PracticeInbox {
    public static let viewerLogin = "you"
    /// Practice thread ids start with this, which no GitHub thread id does.
    public static let idPrefix = "practice-"

    public static func isPractice(_ threadID: String) -> Bool { threadID.hasPrefix(idPrefix) }

    public struct Entry: Sendable {
        public let thread: NotificationThread
        public let facts: SubjectFacts?
    }

    public static func entries(now: Date) -> [Entry] {
        var entries: [Entry] = []
        var next = 0
        func add(
            _ repository: String, _ kind: SubjectKind, _ number: Int?, _ title: String, _ reason: Reason,
            minutesAgo: Double, unread: Bool = true, facts: SubjectFacts? = nil
        ) {
            let parts = repository.split(separator: "/").map(String.init)
            let name = RepositoryName(owner: parts[0], name: parts[1])
            let path = kind == .pullRequest ? "pull" : "issues"
            next += 1
            let thread = NotificationThread(
                id: idPrefix + String(next),
                repository: name,
                kind: kind,
                number: number,
                title: title,
                reason: reason,
                isUnread: unread,
                updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                webURL: URL(string: "https://github.com/\(repository)/\(path)/\(number ?? 0)")!
            )
            entries.append(Entry(thread: thread, facts: facts))
        }
        func pullRequest(
            _ author: String, isApp: Bool = false, state: SubjectFacts.State = .open, draft: Bool = false,
            review: SubjectFacts.ReviewDecision? = nil, checks: SubjectFacts.Checks? = .success,
            yours: Bool = false, request: SubjectFacts.ReviewRequest? = nil
        ) -> SubjectFacts {
            SubjectFacts(
                nodeID: "PR_\(idPrefix)\(next + 1)", state: state, isDraft: draft, reviewDecision: review, checks: checks,
                author: SubjectActor(login: author, isApp: isApp), viewerDidAuthor: yours, pendingReviewRequest: request
            )
        }
        func issue(_ author: String, state: SubjectFacts.State = .open) -> SubjectFacts {
            SubjectFacts(nodeID: "I_\(idPrefix)\(next + 1)", state: state, author: SubjectActor(login: author, isApp: false))
        }

        // Needs me
        add("acme/web", .pullRequest, 4521, "Fix hydration mismatch in checkout", .reviewRequested, minutesAgo: 120,
            facts: pullRequest("mira", checks: .failure, request: .you))
        add("acme/api", .issue, 902, "Rate limiter drops bursts after deploys", .mention, minutesAgo: 15, facts: issue("devon"))
        add("acme/web", .pullRequest, 4498, "Move session cookies to the edge", .author, minutesAgo: 40,
            facts: pullRequest(viewerLogin, review: .changesRequested, yours: true))
        add("acme/mobile", .issue, 311, "Crash when the camera permission is denied", .assign, minutesAgo: 26 * 60, unread: false,
            facts: issue("sam"))
        // Team
        add("acme/api", .pullRequest, 911, "Add tracing to the billing service", .reviewRequested, minutesAgo: 90,
            facts: pullRequest("lee", checks: .pending, request: .team))
        add("acme/design", .issue, 77, "Icon set for the new settings screens", .teamMention, minutesAgo: 300, facts: issue("ana"))
        // Following
        add("acme/web", .pullRequest, 4510, "Lazy-load the help center", .author, minutesAgo: 600, unread: false,
            facts: pullRequest(viewerLogin, review: .reviewRequired, yours: true))
        add("acme/api", .issue, 880, "Docs: pagination limits", .comment, minutesAgo: 200, facts: issue("kai"))
        // A draft that does not ask for you: the Drafts rule moves it to Feed.
        add("acme/web", .pullRequest, 4502, "Try the new router (spike)", .comment, minutesAgo: 50,
            facts: pullRequest("noor", draft: true, checks: nil))
        // Feed: a bot's bundle across repositories
        for (index, (repository, title)) in [
            ("acme/web", "Bump next from 15.1.0 to 15.2.1"),
            ("acme/api", "Bump express from 4.19.2 to 4.21.0"),
            ("acme/mobile", "Bump react-native from 0.79.1 to 0.79.2"),
        ].enumerated() {
            add(repository, .pullRequest, 5000 + index, title, .subscribed, minutesAgo: Double(30 + index * 45),
                facts: pullRequest("dependabot[bot]", isApp: true))
        }
        // Feed: a busy repository
        for (index, title) in ["Typo in the quick start", "Explain retries in the client guide", "Broken link on the API page", "Add a FAQ entry for SSO", "Dark mode screenshots are stale"].enumerated() {
            add("acme/docs", .issue, 120 + index, title, .subscribed, minutesAgo: Double(60 + index * 90), unread: index < 2, facts: issue("guest\(index)"))
        }
        add("acme/web", .release, nil, "v3.4.0", .subscribed, minutesAgo: 180)
        add("acme/api", .workflowRun, nil, "Nightly integration tests failed", .ciActivity, minutesAgo: 420)
        // Cleared by a rule on arrival: merged.
        add("acme/web", .pullRequest, 4480, "Remove the old checkout flag", .comment, minutesAgo: 240,
            facts: pullRequest("mira", state: .merged))
        return entries
    }
}
