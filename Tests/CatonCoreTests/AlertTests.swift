import Foundation
import Testing
@testable import CatonCore

struct AlertTests {
    let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A Wednesday at the given UTC time.
    func wednesday(_ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: hour, minute: minute))!
    }

    func item(_ id: String, updatedAt: Date = reference, unread: Bool = true) -> InboxItem {
        InboxItem(
            thread: makeThread(id: id, reason: .mention, unread: unread, updatedAt: updatedAt),
            classification: Classification(split: .needsMe, badge: .mentioned),
            isUnread: unread
        )
    }

    func decide(_ items: [InboxItem], alerted: [String: Date] = [:], panel: Bool = false, baseline: Bool = false, enabled: Bool = true) -> AlertDecision {
        AlertPolicy.decide(needsMe: items, alerted: alerted, isPanelVisible: panel, quietHours: QuietHours(isEnabled: false), isEnabled: enabled, isBaseline: baseline, now: reference)
    }

    @Test func working_hours_are_not_quiet_and_evenings_and_weekends_are() {
        let hours = QuietHours()
        #expect(!hours.isQuiet(at: wednesday(10), calendar: utc))
        #expect(hours.isQuiet(at: wednesday(8, 59), calendar: utc))
        #expect(hours.isQuiet(at: wednesday(19), calendar: utc))
        let saturday = utc.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        #expect(hours.isQuiet(at: saturday, calendar: utc))
    }

    @Test func a_working_day_can_cross_midnight() {
        let night = QuietHours(start: 22 * 60, end: 6 * 60, weekendsQuiet: false)
        #expect(!night.isQuiet(at: wednesday(23), calendar: utc))
        #expect(!night.isQuiet(at: wednesday(2), calendar: utc))
        #expect(night.isQuiet(at: wednesday(12), calendar: utc))
    }

    @Test func new_unread_items_get_banners_up_to_the_cap_and_the_rest_a_summary() {
        let items = (1...5).map { item("\($0)", updatedAt: reference.addingTimeInterval(Double($0))) }
        let decision = decide(items)
        #expect(decision.banners.map(\.id) == ["5", "4", "3"])
        #expect(decision.overflow == 2)
        #expect(decision.alerted.count == 5)
    }

    @Test func activity_already_alerted_is_not_alerted_again_but_newer_activity_is() {
        #expect(decide([item("1")], alerted: ["1": reference]).banners.isEmpty)
        #expect(decide([item("1", updatedAt: reference.addingTimeInterval(1))], alerted: ["1": reference]).banners.count == 1)
    }

    @Test func the_first_pass_marks_everything_seen_without_banners() {
        let decision = decide([item("1"), item("2")], baseline: true)
        #expect(decision.banners.isEmpty)
        #expect(decision.alerted.count == 2)
    }

    @Test func nothing_is_shown_while_the_panel_is_open_or_alerts_are_off() {
        #expect(decide([item("1")], panel: true).banners.isEmpty)
        #expect(decide([item("1")], enabled: false).banners.isEmpty)
        #expect(decide([item("1")], panel: true).alerted["1"] == reference)
    }

    @Test func read_items_are_marked_seen_without_a_banner() {
        let decision = decide([item("1", unread: false)])
        #expect(decision.banners.isEmpty)
        #expect(decision.alerted["1"] == reference)
    }
}

struct DigestTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // October 2026: the 5th is a Monday, the 3rd a Saturday.
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func the_digest_is_due_once_in_the_morning_of_a_working_day() {
        let hours = QuietHours()
        #expect(DigestPolicy.isDue(lastShown: nil, quietHours: hours, now: date(5, 9, 30), calendar: calendar))
        #expect(!DigestPolicy.isDue(lastShown: date(5, 9, 1), quietHours: hours, now: date(5, 10), calendar: calendar))
        #expect(DigestPolicy.isDue(lastShown: date(5, 9, 1), quietHours: hours, now: date(6, 9, 5), calendar: calendar))
    }

    @Test func the_digest_skips_nights_late_mornings_and_weekends() {
        let hours = QuietHours()
        #expect(!DigestPolicy.isDue(lastShown: nil, quietHours: hours, now: date(5, 7), calendar: calendar))
        #expect(!DigestPolicy.isDue(lastShown: nil, quietHours: hours, now: date(5, 14), calendar: calendar))
        #expect(!DigestPolicy.isDue(lastShown: nil, quietHours: hours, now: date(3, 9, 30), calendar: calendar))
    }

    @Test func the_digest_says_what_waits_and_what_rules_cleared() {
        #expect(DigestPolicy.message(needsMe: 4, clearedOvernight: 37) == "4 need you, 37 cleared overnight")
        #expect(DigestPolicy.message(needsMe: 1, clearedOvernight: 0) == "1 needs you")
        #expect(DigestPolicy.message(needsMe: 0, clearedOvernight: 0) == nil)
    }
}

struct TallyTests {
    @Test func the_week_sums_seven_days_of_clears() {
        var state = LocalState()
        state.count(byRules: 5, now: reference)
        state.count(byYou: 2, now: reference)
        state.count(byRules: 100, now: reference.addingTimeInterval(-8 * 24 * 3600))
        let week = state.week(now: reference)
        #expect(week.byRules == 5)
        #expect(week.byYou == 2)
    }
}
