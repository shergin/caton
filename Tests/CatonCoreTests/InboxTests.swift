import Foundation
import Testing
@testable import CatonCore

struct ActionQueueTests {
    @Test func an_action_waits_out_its_grace_window() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(item: "1", activity: reference)], now: reference, grace: 5)
        #expect(queue.takeDue(now: reference.addingTimeInterval(4)) == nil)
        #expect(queue.takeDue(now: reference.addingTimeInterval(5))?.item == "1")
    }

    @Test func undo_takes_back_the_whole_batch_while_it_is_queued() {
        var queue = ActionQueue()
        let batch = queue.enqueue(.done, [.init(item: "1", activity: reference), .init(item: "2", activity: reference)], now: reference, grace: 5)
        #expect(queue.lastUndoableBatch == batch)
        #expect(queue.undo(batch: batch).count == 2)
        #expect(queue.isEmpty)
    }

    @Test func undo_cannot_take_back_an_action_in_flight() {
        var queue = ActionQueue()
        let batch = queue.enqueue(.done, [.init(item: "1", activity: reference)], now: reference, grace: 0)
        _ = queue.takeDue(now: reference)
        #expect(queue.undo(batch: batch).isEmpty)
        #expect(queue.lastUndoableBatch == nil)
    }

    @Test func a_pending_dismissal_hides_only_the_activity_it_covers() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(item: "1", activity: reference)], now: reference, grace: 5)
        #expect(queue.hides("1", activity: reference))
        #expect(!queue.hides("1", activity: reference.addingTimeInterval(1)))
    }

    @Test func marking_read_does_not_cancel_a_queued_done() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(item: "1", activity: reference)], now: reference, grace: 5)
        queue.enqueue(.markRead, [.init(item: "1", activity: reference)], now: reference, grace: 0)
        #expect(queue.actions.count == 2)
    }

    @Test func a_retryable_failure_is_queued_again_until_attempts_run_out() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(item: "1", activity: reference)], now: reference, grace: 0)
        var now = reference
        for _ in 1..<ActionQueue.maximumAttempts {
            let action = queue.takeDue(now: now)!
            #expect(queue.fail(action.id, retryable: true, now: now) == nil)
            now = now.addingTimeInterval(60)
        }
        let last = queue.takeDue(now: now)!
        #expect(queue.fail(last.id, retryable: true, now: now)?.item == "1")
        #expect(queue.isEmpty)
    }

    @Test func a_relaunch_queues_in_flight_actions_again() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(item: "1", activity: reference)], now: reference, grace: 0)
        _ = queue.takeDue(now: reference)
        queue.resumeAfterLaunch()
        #expect(queue.takeDue(now: reference) != nil)
    }
}

struct InboxProjectionTests {
    func project(
        _ threads: [NotificationThread],
        facts: [String: SubjectFacts] = [:],
        state: LocalState = LocalState(),
        remembered: [ItemID: Resurfacing] = [:],
        now: Date = reference
    ) -> InboxSnapshot {
        InboxProjection.project(threads: threads, facts: { facts[$0.key] }, state: state, remembered: remembered, now: now)
    }

    @Test func threads_land_in_their_splits_newest_first() {
        let snapshot = project([
            makeThread(id: "1", reason: .mention, updatedAt: reference),
            makeThread(id: "2", reason: .mention, updatedAt: reference.addingTimeInterval(10)),
            makeThread(id: "3", reason: .subscribed),
        ], facts: ["3": makeFacts()])
        #expect(snapshot.items(in: .needsMe).map(\.id) == ["2", "1"])
        #expect(snapshot.items(in: .feed).map(\.id) == ["3"])
    }

    @Test func a_dismissed_thread_stays_hidden_until_new_activity_and_then_says_why() {
        var state = LocalState()
        state.dismissals["1"] = Dismissal(cause: .done, activity: reference, at: reference)
        #expect(project([makeThread(id: "1", reason: .mention)], state: state).count(.needsMe) == 0)
        let later = project([makeThread(id: "1", reason: .mention, updatedAt: reference.addingTimeInterval(60))], state: state)
        #expect(later.items(in: .needsMe).first?.resurfacing == .activity)
    }

    @Test func a_returning_thread_names_what_changed() {
        var state = LocalState()
        state.dismissals["1"] = Dismissal(cause: .done, activity: reference, at: reference)
        let newer = reference.addingTimeInterval(60)
        let reRequested = project([makeThread(id: "1", reason: .reviewRequested, updatedAt: newer)], facts: ["1": makeFacts(pendingReviewRequest: .you)], state: state)
        #expect(reRequested.items(in: .needsMe).first?.resurfacing == .reRequested)
        let failing = project([makeThread(id: "1", reason: .author, updatedAt: newer)], facts: ["1": makeFacts(checks: .failure, viewerDidAuthor: true)], state: state)
        #expect(failing.items(in: .needsMe).first?.resurfacing == .checksFailed)
        var commented = makeFacts()
        commented.latestCommenter = SubjectActor(login: "hubot", isApp: false)
        commented.latestCommentAt = newer
        let comment = project([makeThread(id: "1", reason: .comment, updatedAt: newer)], facts: ["1": commented], state: state)
        #expect(comment.items(in: .following).first?.resurfacing == .comment(by: "hubot"))
        #expect(comment.items(in: .following).first?.resurfacing?.note == "back: new comment by @hubot")
    }

    @Test func a_comment_from_before_the_dismissal_is_not_the_news() {
        var state = LocalState()
        state.dismissals["1"] = Dismissal(cause: .unsubscribe, activity: reference, at: reference)
        var facts = makeFacts()
        facts.latestCommenter = SubjectActor(login: "hubot", isApp: false)
        facts.latestCommentAt = reference.addingTimeInterval(-60)
        let snapshot = project([makeThread(id: "1", reason: .mention, updatedAt: reference.addingTimeInterval(60))], facts: ["1": facts], state: state)
        #expect(snapshot.items(in: .needsMe).first?.resurfacing == .askedAgain)
    }

    @Test func a_queued_done_hides_the_thread_at_once() {
        var state = LocalState()
        state.queue.enqueue(.done, [.init(item: "1", activity: reference)], now: reference, grace: 5)
        #expect(project([makeThread(id: "1", reason: .mention)], state: state).count(.needsMe) == 0)
    }

    @Test func a_rule_clear_is_reported_and_not_shown() {
        let snapshot = project([makeThread(id: "1", reason: .subscribed)], facts: ["1": makeFacts(state: .merged)])
        #expect(snapshot.count(.feed) == 0)
        #expect(snapshot.autoClears.map(\.rule) == [.mergedOrClosed])
    }

    @Test func an_undone_rule_leaves_that_activity_alone() {
        var state = LocalState()
        state.ruleExemptions["1"] = reference
        let snapshot = project([makeThread(id: "1", reason: .subscribed)], facts: ["1": makeFacts(state: .merged)], state: state)
        #expect(snapshot.autoClears.isEmpty)
        #expect(snapshot.count(.feed) == 1)
    }

    @Test func a_local_read_mark_shows_the_thread_read_until_new_activity() {
        var state = LocalState()
        state.readMarks["1"] = reference
        #expect(project([makeThread(id: "1", reason: .mention)], state: state).items(in: .needsMe).first?.isUnread == false)
        let newer = project([makeThread(id: "1", reason: .mention, updatedAt: reference.addingTimeInterval(1))], state: state)
        #expect(newer.items(in: .needsMe).first?.isUnread == true)
    }

    @Test func a_snooze_hides_until_its_time() {
        var state = LocalState()
        state.snoozes["1"] = Snooze(until: reference.addingTimeInterval(3600), activity: reference)
        #expect(project([makeThread(id: "1", reason: .mention)], state: state).snoozed.count == 1)
        let after = project([makeThread(id: "1", reason: .mention)], state: state, now: reference.addingTimeInterval(3600))
        #expect(after.items(in: .needsMe).first?.resurfacing == .snoozeEnded)
        #expect(after.wokenSnoozes == ["1": .snoozeEnded])
    }

    @Test func a_follow_up_snooze_comes_back_on_any_activity_or_says_nothing_happened() {
        var state = LocalState()
        state.snoozes["1"] = Snooze(until: reference.addingTimeInterval(3600), activity: reference, onlyIfQuiet: true)
        let thread = makeThread(id: "1", reason: .author)
        #expect(project([thread], facts: ["1": makeFacts(viewerDidAuthor: true)], state: state).snoozed.count == 1)
        let quiet = project([thread], facts: ["1": makeFacts(viewerDidAuthor: true)], state: state, now: reference.addingTimeInterval(3600))
        #expect(quiet.items(in: .following).first?.resurfacing == .noActivity)
        let answered = project([makeThread(id: "1", reason: .author, updatedAt: reference.addingTimeInterval(5))], facts: ["1": makeFacts(viewerDidAuthor: true)], state: state)
        #expect(answered.items(in: .following).first?.resurfacing == .activity)
    }

    @Test func a_snooze_ends_early_on_new_activity_that_needs_the_viewer() {
        var state = LocalState()
        state.snoozes["1"] = Snooze(until: reference.addingTimeInterval(3600), activity: reference)
        let mentioned = project([makeThread(id: "1", reason: .mention, updatedAt: reference.addingTimeInterval(5))], state: state)
        #expect(mentioned.count(.needsMe) == 1)
        let watched = project([makeThread(id: "1", reason: .subscribed, updatedAt: reference.addingTimeInterval(5))], facts: ["1": makeFacts()], state: state)
        #expect(watched.snoozed.count == 1)
    }

    @Test func old_read_threads_leave_the_inbox_but_needs_me_stays() {
        let old = reference.addingTimeInterval(-8 * 24 * 3600)
        let snapshot = project([
            makeThread(id: "1", reason: .subscribed, unread: false, updatedAt: old),
            makeThread(id: "2", reason: .reviewRequested, unread: false, updatedAt: old),
        ], facts: ["1": makeFacts(), "2": makeFacts(pendingReviewRequest: .you)])
        #expect(snapshot.count(.feed) == 0)
        #expect(snapshot.count(.needsMe) == 1)
    }

    @Test func a_remembered_note_shows_until_a_fresher_reason_replaces_it() {
        let snapshot = project([makeThread(id: "1", reason: .mention)], remembered: ["1": .snoozeEnded])
        #expect(snapshot.items(in: .needsMe).first?.resurfacing == .snoozeEnded)
        var state = LocalState()
        state.dismissals["1"] = Dismissal(cause: .done, activity: reference.addingTimeInterval(-10), at: reference.addingTimeInterval(-10))
        let back = project([makeThread(id: "1", reason: .mention)], state: state, remembered: ["1": .snoozeEnded])
        #expect(back.items(in: .needsMe).first?.resurfacing == .activity)
    }
}

struct InboxFeedTests {
    let window: TimeInterval = InboxFeed.recentWindow

    @Test func an_unread_poll_marks_threads_missing_from_it_as_read() {
        let merged = InboxFeed.merge(
            ["1": makeThread(id: "1", unread: true), "2": makeThread(id: "2", unread: true)],
            unread: .changed([makeThread(id: "1", unread: true)]),
            recent: .notModified,
            now: reference,
            recentWindow: window
        )
        #expect(merged.changed)
        #expect(merged.threads["1"]?.isUnread == true)
        #expect(merged.threads["2"]?.isUnread == false)
    }

    @Test func a_newer_unread_copy_wins_over_an_older_read_one() {
        let held = ["1": makeThread(id: "1", unread: true, updatedAt: reference.addingTimeInterval(10))]
        let merged = InboxFeed.merge(
            held,
            unread: .notModified,
            recent: .changed([makeThread(id: "1", unread: false, updatedAt: reference)]),
            now: reference,
            recentWindow: window
        )
        #expect(merged.threads["1"]?.isUnread == true)
        #expect(merged.threads["1"]?.updatedAt == reference.addingTimeInterval(10))
    }

    @Test func an_unchanged_poll_leaves_the_feed_alone() {
        let pastTheHorizon = reference.addingTimeInterval(-TimeInterval(InboxFeed.retainedWindows + 1) * window)
        let held = ["1": makeThread(id: "1", unread: false, updatedAt: pastTheHorizon)]
        let merged = InboxFeed.merge(held, unread: .notModified, recent: .notModified, now: reference, recentWindow: window)
        #expect(!merged.changed)
        #expect(Set(merged.threads.keys) == ["1"])
    }

    @Test func read_threads_older_than_the_horizon_are_forgotten() {
        let pastTheHorizon = reference.addingTimeInterval(-TimeInterval(InboxFeed.retainedWindows + 1) * window)
        let merged = InboxFeed.merge(
            [
                "1": makeThread(id: "1", unread: false, updatedAt: pastTheHorizon),
                "2": makeThread(id: "2", unread: false, updatedAt: reference.addingTimeInterval(-window)),
                "3": makeThread(id: "3", unread: true, updatedAt: pastTheHorizon),
            ],
            unread: .changed([makeThread(id: "3", unread: true, updatedAt: pastTheHorizon)]),
            recent: .notModified,
            now: reference,
            recentWindow: window
        )
        #expect(Set(merged.threads.keys) == ["2", "3"])
    }
}

struct LocalStateTests {
    @Test func a_document_from_an_earlier_version_decodes_with_empty_new_fields() throws {
        let json = #"{"dismissals":{},"readMarks":{"1":0},"snoozes":{},"later":{},"cleared":[],"ruleExemptions":{},"settings":{"enabledRules":["drafts"],"mutedRepositories":[],"aiReviewerLogins":[],"agentLogins":[]},"queue":{"actions":[]}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state = try decoder.decode(LocalState.self, from: Data(json.utf8))
        #expect(state.readMarks.count == 1)
        #expect(state.alerted.isEmpty)
        #expect(state.settings.enabledRules == [.drafts])
    }

    @Test func typed_ids_save_and_load_in_the_format_strings_had() throws {
        var state = LocalState()
        state.dismissals[.thread("123")] = Dismissal(cause: .done, activity: reference, at: reference)
        state.dismissals[.reviewRequest("PR_1")] = Dismissal(cause: .done, activity: reference, at: reference)
        state.queue.enqueue(.done, [.init(item: .reviewRequest("PR_1"), activity: reference)], now: reference, grace: 5)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = String(decoding: try encoder.encode(state), as: UTF8.self)
        #expect(json.contains(#""review:PR_1""#) && json.contains(#""123""#) && json.contains(#""threadID":"review:PR_1""#))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(LocalState.self, from: Data(json.utf8))
        #expect(Set(decoded.dismissals.keys) == [.thread("123"), .reviewRequest("PR_1")])
        #expect(decoded.queue.actions.first?.item == .reviewRequest("PR_1"))
    }

    @Test func a_snooze_saved_before_follow_ups_decodes_as_an_ordinary_snooze() throws {
        let json = #"{"snoozes":{"1":{"until":10,"activity":5}}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state = try decoder.decode(LocalState.self, from: Data(json.utf8))
        #expect(state.snoozes["1"]?.onlyIfQuiet == false)
    }

    @Test func read_marks_the_feed_agrees_with_are_dropped() {
        var state = LocalState()
        state.readMarks["1"] = reference
        state.readMarks["2"] = reference
        state.readMarks["3"] = reference
        state.readMarks[.reviewRequest("PR")] = reference
        state.reconcileReads(with: [
            "1": makeThread(id: "1", unread: false, updatedAt: reference),
            "2": makeThread(id: "2", unread: true, updatedAt: reference),
            "3": makeThread(id: "3", unread: true, updatedAt: reference.addingTimeInterval(1)),
        ])
        #expect(state.readMarks == ["2": reference])
    }
}
