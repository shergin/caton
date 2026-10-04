import Foundation

/// Why a thread the user took away is back, as specific as the facts allow.
public enum Resurfacing: Hashable, Sendable {
    case reRequested
    case changesRequested
    case checksFailed
    case approved
    case comment(by: String)
    /// Unsubscribed, and GitHub notified the user anyway: a mention, an
    /// assignment or a review request.
    case askedAgain
    case activity
    case snoozeEnded
    /// A snooze that waited for silence ended, and nothing happened.
    case noActivity

    public var note: String {
        switch self {
        case .reRequested: "back: re-requested"
        case .changesRequested: "back: changes requested"
        case .checksFailed: "back: checks failed"
        case .approved: "back: approved"
        case .comment(let login): "back: new comment by @\(login)"
        case .askedAgain: "back: you were asked again"
        case .activity: "back: new activity"
        case .snoozeEnded: "back: snooze ended"
        case .noActivity: "back: no reply yet"
        }
    }

    /// Why activity after `since` brought a thread back, read from what the
    /// thread is now: the most specific change first.
    public static func newActivity(since: Date, badge: Badge, facts: SubjectFacts?, afterUnsubscribe: Bool = false) -> Resurfacing {
        switch badge {
        case .reviewYou: return .reRequested
        case .yourPullRequest(.changesRequested): return .changesRequested
        case .yourPullRequest(.checksFailed): return .checksFailed
        case .yourPullRequest(.readyToMerge): return .approved
        default: break
        }
        if let facts, let at = facts.latestCommentAt, at > since, let commenter = facts.latestCommenter {
            return .comment(by: commenter.login)
        }
        return afterUnsubscribe ? .askedAgain : .activity
    }
}

/// One row of the inbox.
public struct InboxItem: Identifiable, Hashable, Sendable {
    public var thread: NotificationThread
    public var classification: Classification
    public var isUnread: Bool
    public var resurfacing: Resurfacing?

    public var id: String { thread.id }
}

/// A thread a rule wants cleared.
public struct AutoClear: Hashable, Sendable {
    public let thread: NotificationThread
    public let rule: Rule
    public let subjectNodeID: String?
}

/// The inbox as the user sees it at one moment.
public struct InboxSnapshot: Equatable, Sendable {
    public var splits: [Split: [InboxItem]] = [:]
    public var snoozed: [InboxItem] = []
    public var later: [InboxItem] = []
    /// Threads rules clear on this pass; the app enqueues them.
    public var autoClears: [AutoClear] = []
    /// Snoozes that ended on this pass, with why; the app forgets them.
    public var wokenSnoozes: [String: Resurfacing] = [:]

    public init() {}

    public func items(in split: Split) -> [InboxItem] { splits[split] ?? [] }

    public func count(_ split: Split) -> Int { splits[split]?.count ?? 0 }
}

/// Computes the inbox from the feed, the subjects' facts and local state.
/// Pure, so every rule about what shows where is testable without a network.
public enum InboxProjection {
    /// How long a read thread outside Needs me stays in the inbox.
    public static let readRetention: TimeInterval = 7 * 24 * 3600

    public static func project(
        threads: some Sequence<NotificationThread>,
        facts: (NotificationThread) -> SubjectFacts?,
        state: LocalState,
        now: Date
    ) -> InboxSnapshot {
        var snapshot = InboxSnapshot()
        for thread in threads {
            if state.queue.hides(threadID: thread.id, activity: thread.updatedAt) { continue }

            let subjectFacts = facts(thread)
            let classification = Classifier.classify(thread, facts: subjectFacts, settings: state.settings)

            var resurfacing: Resurfacing?
            if let dismissal = state.dismissals[thread.id] {
                if thread.updatedAt <= dismissal.activity { continue }
                let unsubscribed = dismissal.cause == .unsubscribe || dismissal.cause == .ignore
                resurfacing = .newActivity(since: dismissal.activity, badge: classification.badge, facts: subjectFacts, afterUnsubscribe: unsubscribed)
            }

            if let rule = classification.clearedBy {
                let exempt = state.ruleExemptions[thread.id].map { thread.updatedAt <= $0 } ?? false
                if !exempt {
                    snapshot.autoClears.append(AutoClear(thread: thread, rule: rule, subjectNodeID: subjectFacts?.nodeID))
                    continue
                }
            }

            let readMark = state.readMarks[thread.id]
            let isUnread = thread.isUnread && !(readMark.map { thread.updatedAt <= $0 } ?? false)
            var item = InboxItem(thread: thread, classification: classification, isUnread: isUnread, resurfacing: resurfacing)

            if let snooze = state.snoozes[thread.id] {
                if let woke = snooze.wake(thread: thread, split: classification.split, now: now) {
                    let why: Resurfacing = switch woke {
                    case .time: snooze.onlyIfQuiet ? .noActivity : .snoozeEnded
                    case .activity: .newActivity(since: snooze.activity, badge: classification.badge, facts: subjectFacts)
                    }
                    snapshot.wokenSnoozes[thread.id] = why
                    item.resurfacing = why
                } else {
                    snapshot.snoozed.append(item)
                    continue
                }
            }

            if state.later[thread.id] != nil {
                snapshot.later.append(item)
                continue
            }

            if !isUnread, classification.split != .needsMe, now.timeIntervalSince(thread.updatedAt) > readRetention {
                continue
            }

            snapshot.splits[classification.split, default: []].append(item)
        }

        for split in Split.allCases {
            snapshot.splits[split]?.sort(by: newestFirst)
        }
        snapshot.snoozed.sort(by: newestFirst)
        snapshot.later.sort { (state.later[$0.id] ?? .distantPast) > (state.later[$1.id] ?? .distantPast) }
        return snapshot
    }

    private static func newestFirst(_ lhs: InboxItem, _ rhs: InboxItem) -> Bool {
        if lhs.thread.updatedAt != rhs.thread.updatedAt { return lhs.thread.updatedAt > rhs.thread.updatedAt }
        return lhs.id > rhs.id
    }
}
