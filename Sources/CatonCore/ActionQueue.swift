import Foundation

/// A change Caton sends to GitHub on the user's behalf.
public enum Verb: String, Codable, Sendable {
    case markRead
    case done
    case unsubscribe
    case ignore

    /// Whether the verb removes the thread from the inbox.
    public var dismisses: Bool { self != .markRead }
}

/// One verb for one thread, waiting for its grace window or in flight.
public struct QueuedAction: Codable, Identifiable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case queued
        case inFlight
    }

    public let id: UUID
    /// The actions enqueued together; undo works on a batch.
    public let batch: UUID
    /// The row the verb is for. Only a thread reaches GitHub; for a review
    /// request the verb is recorded here alone.
    public let item: ItemID
    public let verb: Verb
    /// The thread's `updatedAt` when the user acted: the activity the verb covers.
    public let activity: Date
    /// The subject's GraphQL id, for verbs that go through GraphQL.
    public let subjectNodeID: String?
    /// The rule that enqueued the action, when the user did not.
    public let rule: Rule?
    public internal(set) var notBefore: Date
    public internal(set) var attempts: Int
    public internal(set) var phase: Phase

    /// Saved under the name it had when only threads were queued.
    private enum CodingKeys: String, CodingKey {
        case id, batch, item = "threadID", verb, activity, subjectNodeID, rule, notBefore, attempts, phase
    }
}

/// The persisted queue behind every optimistic action. Pure state: the app
/// decides when to dispatch, this decides what is due, what undo removes and
/// what the inbox hides meanwhile.
public struct ActionQueue: Codable, Hashable, Sendable {
    public struct Target: Hashable, Sendable {
        public let item: ItemID
        public let activity: Date
        public let subjectNodeID: String?

        public init(item: ItemID, activity: Date, subjectNodeID: String? = nil) {
            self.item = item
            self.activity = activity
            self.subjectNodeID = subjectNodeID
        }
    }

    public static let maximumAttempts = 3

    public private(set) var actions: [QueuedAction] = []

    public init() {}

    public var isEmpty: Bool { actions.isEmpty }

    /// Enqueues one verb for each target as one batch. A queued dismissal for
    /// the same thread is replaced by a later one: the latest decision wins.
    @discardableResult
    public mutating func enqueue(_ verb: Verb, _ targets: [Target], rule: Rule? = nil, now: Date, grace: TimeInterval) -> UUID {
        let batch = UUID()
        let items = Set(targets.map(\.item))
        actions.removeAll { $0.phase == .queued && items.contains($0.item) && $0.verb.dismisses == verb.dismisses }
        for target in targets {
            actions.append(QueuedAction(
                id: UUID(),
                batch: batch,
                item: target.item,
                verb: verb,
                activity: target.activity,
                subjectNodeID: target.subjectNodeID,
                rule: rule,
                notBefore: now.addingTimeInterval(grace),
                attempts: 0,
                phase: .queued
            ))
        }
        return batch
    }

    /// The dismissing action pending for a row, queued or in flight.
    public func pendingDismissal(for item: ItemID) -> QueuedAction? {
        actions.last { $0.item == item && $0.verb.dismisses }
    }

    /// Whether a pending action hides this activity of the row. New
    /// activity after the action was taken shows it again.
    public func hides(_ item: ItemID, activity: Date) -> Bool {
        guard let pending = pendingDismissal(for: item) else { return false }
        return activity <= pending.activity
    }

    /// The most recent batch that still has something to take back.
    public var lastUndoableBatch: UUID? {
        actions.last { $0.phase == .queued && $0.verb.dismisses }?.batch
    }

    /// Removes the queued actions of a batch and returns them. Actions already
    /// in flight cannot be taken back.
    public mutating func undo(batch: UUID) -> [QueuedAction] {
        let removed = actions.filter { $0.batch == batch && $0.phase == .queued }
        actions.removeAll { $0.batch == batch && $0.phase == .queued }
        return removed
    }

    /// The next action whose grace window has passed, now marked in flight.
    public mutating func takeDue(now: Date) -> QueuedAction? {
        guard let index = actions.indices
            .filter({ actions[$0].phase == .queued && actions[$0].notBefore <= now })
            .min(by: { actions[$0].notBefore < actions[$1].notBefore })
        else { return nil }
        actions[index].phase = .inFlight
        actions[index].attempts += 1
        return actions[index]
    }

    /// When the next queued action becomes due.
    public var nextDueDate: Date? {
        actions.filter { $0.phase == .queued }.map(\.notBefore).min()
    }

    public mutating func complete(_ id: UUID) {
        actions.removeAll { $0.id == id }
    }

    /// Puts a failed action back with a backoff, or drops it and returns it
    /// when it cannot succeed or has run out of attempts.
    public mutating func fail(_ id: UUID, retryable: Bool, now: Date) -> QueuedAction? {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return nil }
        if retryable, actions[index].attempts < Self.maximumAttempts {
            actions[index].phase = .queued
            actions[index].notBefore = now.addingTimeInterval(Double(actions[index].attempts) * 5)
            return nil
        }
        return actions.remove(at: index)
    }

    /// After a relaunch nothing is in flight: what was is queued again.
    public mutating func resumeAfterLaunch() {
        for index in actions.indices where actions[index].phase == .inFlight {
            actions[index].phase = .queued
        }
    }

    /// Makes every queued action due now, for a quit.
    public mutating func expedite(now: Date) {
        for index in actions.indices where actions[index].phase == .queued {
            actions[index].notBefore = now
        }
    }
}
