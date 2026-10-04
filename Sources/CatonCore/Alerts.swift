import Foundation

/// When banners stay silent.
public struct QuietHours: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Minutes after midnight when the working day starts and ends.
    public var start: Int
    public var end: Int
    public var weekendsQuiet: Bool

    public init(isEnabled: Bool = true, start: Int = 9 * 60, end: Int = 19 * 60, weekendsQuiet: Bool = true) {
        self.isEnabled = isEnabled
        self.start = start
        self.end = end
        self.weekendsQuiet = weekendsQuiet
    }

    /// Whether a moment falls outside working hours.
    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        if weekendsQuiet, calendar.isDateInWeekend(date) { return true }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start <= end { return minute < start || minute >= end }
        // A working day that crosses midnight.
        return minute < start && minute >= end
    }
}

/// What to show for new Needs me items on one pass.
public struct AlertDecision: Equatable, Sendable {
    /// Items to show a banner for, newest first.
    public var banners: [InboxItem] = []
    /// How many more arrived than the cap allowed; shown as one summary banner.
    public var overflow = 0
    /// Activity now accounted for, alerted or deliberately not.
    public var alerted: [String: Date] = [:]
}

/// Decides banners: only Needs me, only new activity, at most a few per
/// pass, never while the panel is open or during quiet hours. Activity that
/// arrives while silent is marked seen rather than held, so quiet hours do
/// not end in a burst.
public enum AlertPolicy {
    public static let defaultCap = 3

    public static func decide(
        needsMe: [InboxItem],
        alerted: [String: Date],
        isPanelVisible: Bool,
        quietHours: QuietHours,
        isEnabled: Bool,
        isBaseline: Bool,
        cap: Int = defaultCap,
        now: Date
    ) -> AlertDecision {
        var decision = AlertDecision()
        let fresh = needsMe.filter { item in
            alerted[item.id].map { item.thread.updatedAt > $0 } ?? true
        }
        for item in fresh { decision.alerted[item.id] = item.thread.updatedAt }
        guard isEnabled, !isBaseline, !isPanelVisible, !quietHours.isQuiet(at: now) else { return decision }
        let unread = fresh.filter(\.isUnread).sorted { $0.thread.updatedAt > $1.thread.updatedAt }
        decision.banners = Array(unread.prefix(cap))
        decision.overflow = max(0, unread.count - cap)
        return decision
    }
}

/// The optional morning digest: one banner when the working day starts,
/// "4 need you, 37 cleared overnight".
public enum DigestPolicy {
    /// How long after the day's start the digest may still show; opening the
    /// Mac at noon does not get a morning digest.
    public static let window: TimeInterval = 4 * 3600

    /// Whether the digest is due: on a working day, within the window after
    /// the day starts, once.
    public static func isDue(lastShown: Date?, quietHours: QuietHours, now: Date, calendar: Calendar = .current) -> Bool {
        let start = dayStart(of: now, quietHours: quietHours, calendar: calendar)
        guard now >= start, now < start.addingTimeInterval(window) else { return false }
        if quietHours.weekendsQuiet, calendar.isDateInWeekend(now) { return false }
        if let lastShown, lastShown >= start { return false }
        return true
    }

    /// When the working day of `date` starts: quiet hours' end, else 9:00.
    public static func dayStart(of date: Date, quietHours: QuietHours, calendar: Calendar = .current) -> Date {
        let minutes = quietHours.isEnabled ? quietHours.start : 9 * 60
        return calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(minutes * 60))
    }

    public static func message(needsMe: Int, clearedOvernight: Int) -> String? {
        guard needsMe > 0 || clearedOvernight > 0 else { return nil }
        let waiting = needsMe == 0 ? "Nothing needs you" : "\(needsMe) need\(needsMe == 1 ? "s" : "") you"
        return clearedOvernight == 0 ? waiting : "\(waiting), \(clearedOvernight) cleared overnight"
    }
}
