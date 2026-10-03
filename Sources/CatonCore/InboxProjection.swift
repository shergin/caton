import Foundation

/// Why a thread the user took away is back.
public enum Resurfacing: Hashable, Sendable {
    case afterDone
    case afterUnsubscribe
    case afterRule(Rule)
    case snoozeEnded

    public var note: String {
        switch self {
        case .afterDone: "back: new activity since done"
        case .afterUnsubscribe: "back: you were asked again"
        case .afterRule: "back: new activity"
        case .snoozeEnded: "back: snooze ended"
        }
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
    /// Snoozes that ended on this pass; the app forgets them.
    public var wokenSnoozes: [String] = []

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

            var resurfacing: Resurfacing?
            if let dismissal = state.dismissals[thread.id] {
                if thread.updatedAt <= dismissal.activity { continue }
                switch dismissal.cause {
                case .done: resurfacing = .afterDone
                case .unsubscribe, .ignore: resurfacing = .afterUnsubscribe
                case .rule(let rule): resurfacing = .afterRule(rule)
                }
            }

            let subjectFacts = facts(thread)
            let classification = Classifier.classify(thread, facts: subjectFacts, settings: state.settings)

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
                let woke = now >= snooze.until || (thread.updatedAt > snooze.activity && classification.split == .needsMe)
                if !woke {
                    snapshot.snoozed.append(item)
                    continue
                }
                snapshot.wokenSnoozes.append(thread.id)
                item.resurfacing = .snoozeEnded
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
