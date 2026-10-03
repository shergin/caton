import Foundation
import Testing
@testable import CatonCore

struct ActionQueueTests {
    @Test func an_action_waits_out_its_grace_window() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(threadID: "1", activity: reference)], now: reference, grace: 5)
        #expect(queue.takeDue(now: reference.addingTimeInterval(4)) == nil)
        #expect(queue.takeDue(now: reference.addingTimeInterval(5))?.threadID == "1")
    }

    @Test func undo_takes_back_the_whole_batch_while_it_is_queued() {
        var queue = ActionQueue()
        let batch = queue.enqueue(.done, [.init(threadID: "1", activity: reference), .init(threadID: "2", activity: reference)], now: reference, grace: 5)
        #expect(queue.lastUndoableBatch == batch)
        #expect(queue.undo(batch: batch).count == 2)
        #expect(queue.isEmpty)
    }

    @Test func undo_cannot_take_back_an_action_in_flight() {
        var queue = ActionQueue()
        let batch = queue.enqueue(.done, [.init(threadID: "1", activity: reference)], now: reference, grace: 0)
        _ = queue.takeDue(now: reference)
        #expect(queue.undo(batch: batch).isEmpty)
        #expect(queue.lastUndoableBatch == nil)
    }

    @Test func a_pending_dismissal_hides_only_the_activity_it_covers() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(threadID: "1", activity: reference)], now: reference, grace: 5)
        #expect(queue.hides(threadID: "1", activity: reference))
        #expect(!queue.hides(threadID: "1", activity: reference.addingTimeInterval(1)))
    }

    @Test func marking_read_does_not_cancel_a_queued_done() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(threadID: "1", activity: reference)], now: reference, grace: 5)
        queue.enqueue(.markRead, [.init(threadID: "1", activity: reference)], now: reference, grace: 0)
        #expect(queue.actions.count == 2)
    }

    @Test func a_retryable_failure_is_queued_again_until_attempts_run_out() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(threadID: "1", activity: reference)], now: reference, grace: 0)
        var now = reference
        for _ in 1..<ActionQueue.maximumAttempts {
            let action = queue.takeDue(now: now)!
            #expect(queue.fail(action.id, retryable: true, now: now) == nil)
            now = now.addingTimeInterval(60)
        }
        let last = queue.takeDue(now: now)!
        #expect(queue.fail(last.id, retryable: true, now: now)?.threadID == "1")
        #expect(queue.isEmpty)
    }

    @Test func a_relaunch_queues_in_flight_actions_again() {
        var queue = ActionQueue()
        queue.enqueue(.done, [.init(threadID: "1", activity: reference)], now: reference, grace: 0)
        _ = queue.takeDue(now: reference)
        queue.resumeAfterLaunch()
        #expect(queue.takeDue(now: reference) != nil)
    }
}

struct InboxProjectionTests {
    func project(_ threads: [NotificationThread], facts: [String: SubjectFacts] = [:], state: LocalState = LocalState(), now: Date = reference) -> InboxSnapshot {
        InboxProjection.project(threads: threads, facts: { facts[$0.id] }, state: state, now: now)
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
        #expect(later.items(in: .needsMe).first?.resurfacing == .afterDone)
    }

    @Test func a_queued_done_hides_the_thread_at_once() {
        var state = LocalState()
        state.queue.enqueue(.done, [.init(threadID: "1", activity: reference)], now: reference, grace: 5)
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
        #expect(after.wokenSnoozes == ["1"])
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
}
