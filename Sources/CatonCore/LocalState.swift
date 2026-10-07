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

/// A thread hidden until a time, or until new activity. An ordinary snooze
/// ends early only for activity that needs the user; one that waits for
/// silence (a follow-up on the user's own pull request) ends on any activity,
/// and at its time says nothing happened.
public struct Snooze: Codable, Hashable, Sendable {
    public enum Wake: Sendable {
        case time
        case activity
    }

    public var until: Date
    public var activity: Date
    public var onlyIfQuiet: Bool

    public init(until: Date, activity: Date, onlyIfQuiet: Bool = false) {
        self.until = until
        self.activity = activity
        self.onlyIfQuiet = onlyIfQuiet
    }

    private enum CodingKeys: String, CodingKey {
        case until, activity, onlyIfQuiet
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        until = try container.decode(Date.self, forKey: .until)
        activity = try container.decode(Date.self, forKey: .activity)
        onlyIfQuiet = try container.decodeIfPresent(Bool.self, forKey: .onlyIfQuiet) ?? false
    }

    /// Whether, and why, the snooze is over for the thread as it is now.
    public func wake(thread: NotificationThread, split: Split, now: Date) -> Wake? {
        if thread.updatedAt > activity, onlyIfQuiet || split == .needsMe { return .activity }
        return now >= until ? .time : nil
    }
}

/// One thread a rule or a bulk clear took away, for the Cleared view.
public struct ClearedEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let batch: UUID
    public let item: ItemID
    public let reference: String
    public let title: String
    public let webURL: URL
    public let rule: Rule?
    public let at: Date

    public init(batch: UUID, thread: NotificationThread, rule: Rule?, at: Date) {
        id = UUID()
        self.batch = batch
        item = .thread(thread.id)
        reference = thread.reference
        title = thread.title
        webURL = thread.webURL
        self.rule = rule
        self.at = at
    }

    /// Saved under the name it had when only threads were cleared.
    private enum CodingKeys: String, CodingKey {
        case id, batch, item = "threadID", reference, title, webURL, rule, at
    }
}

/// A search kept as a split of its own.
public struct SavedSearch: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var query: String

    public init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// What was cleared on one day, for the local-only stats.
public struct Tally: Codable, Hashable, Sendable {
    /// Threads rules cleared.
    public var byRules = 0
    /// Threads the user marked done, unsubscribed from or ignored.
    public var byYou = 0

    public init(byRules: Int = 0, byYou: Int = 0) {
        self.byRules = byRules
        self.byYou = byYou
    }
}

/// Everything Caton knows that GitHub does not: dismissals until the feed
/// agrees, local read marks, snoozes, the Later list, the Cleared log, rule
/// exemptions, settings and the action queue. Persisted as one document.
public struct LocalState: Codable, Hashable, Sendable {
    public var dismissals: [ItemID: Dismissal] = [:]
    /// Activity marked read here, until the feed reports it read.
    public var readMarks: [ItemID: Date] = [:]
    public var snoozes: [ItemID: Snooze] = [:]
    /// Threads saved for later, with when they were saved.
    public var later: [ItemID: Date] = [:]
    public var cleared: [ClearedEntry] = []
    /// Activity a rule must leave alone because the user undid the rule.
    public var ruleExemptions: [ItemID: Date] = [:]
    public var settings = ClassifierSettings()
    public var queue = ActionQueue()
    /// The activity of each Needs me thread a banner already covered.
    public var alerted: [ItemID: Date] = [:]
    /// Clears per day (`yyyy-MM-dd`), kept two weeks. Never leaves the Mac.
    public var tallies: [String: Tally] = [:]
    public var savedSearches: [SavedSearch] = []
    /// Reminders on the viewer's own pull requests, by pull request node id.
    public var followUps: [String: FollowUp] = [:]

    public static let clearedRetention: TimeInterval = 7 * 24 * 3600
    public static let dismissalRetention: TimeInterval = 30 * 24 * 3600

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case dismissals, readMarks, snoozes, later, cleared, ruleExemptions, settings, queue, alerted, tallies, savedSearches, followUps
    }

    /// Reads documents written by earlier versions: a missing key is empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dismissals = try container.decodeIfPresent([ItemID: Dismissal].self, forKey: .dismissals) ?? [:]
        readMarks = try container.decodeIfPresent([ItemID: Date].self, forKey: .readMarks) ?? [:]
        snoozes = try container.decodeIfPresent([ItemID: Snooze].self, forKey: .snoozes) ?? [:]
        later = try container.decodeIfPresent([ItemID: Date].self, forKey: .later) ?? [:]
        cleared = try container.decodeIfPresent([ClearedEntry].self, forKey: .cleared) ?? []
        ruleExemptions = try container.decodeIfPresent([ItemID: Date].self, forKey: .ruleExemptions) ?? [:]
        settings = try container.decodeIfPresent(ClassifierSettings.self, forKey: .settings) ?? ClassifierSettings()
        queue = try container.decodeIfPresent(ActionQueue.self, forKey: .queue) ?? ActionQueue()
        alerted = try container.decodeIfPresent([ItemID: Date].self, forKey: .alerted) ?? [:]
        tallies = try container.decodeIfPresent([String: Tally].self, forKey: .tallies) ?? [:]
        savedSearches = try container.decodeIfPresent([SavedSearch].self, forKey: .savedSearches) ?? []
        followUps = try container.decodeIfPresent([String: FollowUp].self, forKey: .followUps) ?? [:]
    }

    /// Counts clears for the day of `now`.
    public mutating func count(byRules: Int = 0, byYou: Int = 0, now: Date) {
        let day = Self.day(now)
        tallies[day, default: Tally()].byRules += byRules
        tallies[day, default: Tally()].byYou += byYou
    }

    /// The last seven days' clears, today included.
    public func week(now: Date) -> Tally {
        let calendar = Calendar(identifier: .gregorian)
        let days = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: now).map(Self.day) })
        return tallies.filter { days.contains($0.key) }.values.reduce(into: Tally()) { total, tally in
            total.byRules += tally.byRules
            total.byYou += tally.byYou
        }
    }

    static func day(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Records rule clears. When `syncToGitHub` is set they wait in the queue
    /// and are marked done after the grace window; otherwise they are
    /// dismissals on this Mac only, until the user opts in.
    public mutating func applyRuleClears(_ clears: [AutoClear], syncToGitHub: Bool, now: Date, grace: TimeInterval) {
        count(byRules: clears.count, now: now)
        let byRule = Dictionary(grouping: clears, by: \.rule)
        for (rule, clears) in byRule {
            if syncToGitHub {
                let batch = queue.enqueue(.done, clears.map { .init(item: $0.id, activity: $0.thread.updatedAt, subjectNodeID: $0.subjectNodeID) }, rule: rule, now: now, grace: grace)
                self.cleared += clears.map { ClearedEntry(batch: batch, thread: $0.thread, rule: rule, at: now) }
            } else {
                let batch = UUID()
                for clear in clears {
                    dismissals[clear.id] = Dismissal(cause: .rule(rule), activity: clear.thread.updatedAt, at: now)
                }
                self.cleared += clears.map { ClearedEntry(batch: batch, thread: $0.thread, rule: rule, at: now) }
            }
        }
    }

    /// Drops read marks the feed now agrees with. A mark stays only while the
    /// thread is still unread at the activity the mark covers.
    public mutating func reconcileReads(with threads: [String: NotificationThread]) {
        readMarks = readMarks.filter { id, mark in
            guard case .thread(let threadID) = id, let thread = threads[threadID] else { return false }
            return thread.isUnread && thread.updatedAt <= mark
        }
    }

    /// Drops what no longer matters: old Cleared entries, and dismissals,
    /// marks and exemptions for threads the feed no longer returns.
    public mutating func prune(liveIDs: Set<ItemID>, now: Date) {
        cleared.removeAll { now.timeIntervalSince($0.at) > Self.clearedRetention }
        dismissals = dismissals.filter { id, dismissal in
            liveIDs.contains(id) || now.timeIntervalSince(dismissal.at) < Self.dismissalRetention
        }
        readMarks = readMarks.filter { liveIDs.contains($0.key) }
        ruleExemptions = ruleExemptions.filter { liveIDs.contains($0.key) }
        alerted = alerted.filter { liveIDs.contains($0.key) }
        let oldest = Self.day(now.addingTimeInterval(-14 * 24 * 3600))
        tallies = tallies.filter { $0.key >= oldest }
    }
}
