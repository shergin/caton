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
    public static let cap = 3

    public static func decide(
        needsMe: [InboxItem],
        alerted: [String: Date],
        isPanelVisible: Bool,
        quietHours: QuietHours,
        isEnabled: Bool,
        isBaseline: Bool,
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
