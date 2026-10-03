import Foundation

/// A thread the user or a rule took out of the inbox, and which activity it
/// covered. New activity brings the thread back.
public struct Dismissal: Codable, Hashable, Sendable {
    public enum Cause: Codable, Hashable, Sendable {
        case done
        case unsubscribe
        case ignore
        case rule(Rule)
    }

    public var cause: Cause
    public var activity: Date
    public var at: Date

    public init(cause: Cause, activity: Date, at: Date) {
        self.cause = cause
        self.activity = activity
        self.at = at
    }
}

/// A thread hidden until a time, or until new activity that needs the user.
public struct Snooze: Codable, Hashable, Sendable {
    public var until: Date
    public var activity: Date

    public init(until: Date, activity: Date) {
        self.until = until
        self.activity = activity
    }
}

/// One thread a rule or a bulk clear took away, for the Cleared view.
public struct ClearedEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let batch: UUID
    public let threadID: String
    public let reference: String
    public let title: String
    public let webURL: URL
    public let rule: Rule?
    public let at: Date

    public init(batch: UUID, thread: NotificationThread, rule: Rule?, at: Date) {
        id = UUID()
        self.batch = batch
        threadID = thread.id
        reference = thread.reference
        title = thread.title
        webURL = thread.webURL
        self.rule = rule
        self.at = at
    }
}

/// Everything Caton knows that GitHub does not: dismissals until the feed
/// agrees, local read marks, snoozes, the Later list, the Cleared log, rule
/// exemptions, settings and the action queue. Persisted as one document.
public struct LocalState: Codable, Hashable, Sendable {
    public var dismissals: [String: Dismissal] = [:]
    /// Activity marked read here, until the feed reports it read.
    public var readMarks: [String: Date] = [:]
    public var snoozes: [String: Snooze] = [:]
    /// Threads saved for later, with when they were saved.
    public var later: [String: Date] = [:]
    public var cleared: [ClearedEntry] = []
    /// Activity a rule must leave alone because the user undid the rule.
    public var ruleExemptions: [String: Date] = [:]
    public var settings = ClassifierSettings()
    public var queue = ActionQueue()

    public static let clearedRetention: TimeInterval = 7 * 24 * 3600
    public static let dismissalRetention: TimeInterval = 30 * 24 * 3600

    public init() {}

    /// Drops what no longer matters: old Cleared entries, and dismissals,
    /// marks and exemptions for threads the feed no longer returns.
    public mutating func prune(liveThreadIDs: Set<String>, now: Date) {
        cleared.removeAll { now.timeIntervalSince($0.at) > Self.clearedRetention }
        dismissals = dismissals.filter { id, dismissal in
            liveThreadIDs.contains(id) || now.timeIntervalSince(dismissal.at) < Self.dismissalRetention
        }
        readMarks = readMarks.filter { liveThreadIDs.contains($0.key) }
        ruleExemptions = ruleExemptions.filter { liveThreadIDs.contains($0.key) }
    }
}
