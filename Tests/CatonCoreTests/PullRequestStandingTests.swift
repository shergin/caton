import Foundation
import Testing
@testable import CatonCore

struct PullRequestStandingTests {
    let created = reference.addingTimeInterval(-5 * 24 * 3600)

    func standing(_ build: (inout PullRequestStatus) -> Void) -> PullRequestStanding {
        var status = PullRequestStatus(createdAt: created)
        build(&status)
        return .of(status)
    }

    @Test func a_draft_is_a_draft_whatever_else_holds() {
        #expect(standing { $0.isDraft = true; $0.checks = .failure } == .draft)
    }

    @Test func what_blocks_a_merge_comes_before_approval() {
        #expect(standing { $0.mergeable = .conflicting; $0.reviewDecision = .approved } == .conflicts)
        #expect(standing { $0.checks = .failure; $0.reviewDecision = .approved } == .checksFailing)
        let changes = standing {
            $0.reviewDecision = .changesRequested
            $0.latestReviews = [.init(login: "alex", state: .changesRequested), .init(login: "sam", state: .approved)]
        }
        #expect(changes == .changesRequested(by: ["alex"]))
    }

    @Test func approval_reads_ready_or_waits_for_checks() {
        #expect(standing { $0.reviewDecision = .approved; $0.checks = .success } == .readyToMerge)
        #expect(standing { $0.reviewDecision = .approved; $0.checks = .pending } == .approvedChecksRunning)
        // Without branch protection there is no decision; an approval still counts.
        #expect(standing { $0.latestReviews = [.init(login: "sam", state: .approved)] } == .readyToMerge)
    }

    @Test func a_pending_request_waits_on_its_reviewers_since_the_request() {
        let requested = reference.addingTimeInterval(-3 * 24 * 3600)
        let result = standing {
            $0.pendingReviewers = [.init(name: "alex"), .init(name: "acme/web", isTeam: true)]
            $0.requestedAt = requested
        }
        #expect(result == .waitingOnReview(from: [.init(name: "alex"), .init(name: "acme/web", isTeam: true)], since: requested))
        #expect(result.summary(now: reference) == "waiting on @alex and @acme/web · 3d")
        #expect(result.group == .waiting)
    }

    @Test func nobody_asked_to_review_is_the_authors_move() {
        let result = standing { _ in }
        #expect(result == .noReviewer(since: created))
        #expect(result.group == .yourMove)
    }

    @Test func a_nudge_asks_pending_reviewers_and_those_who_wanted_changes() {
        var status = PullRequestStatus(createdAt: created)
        status.pendingReviewers = [.init(name: "alex", id: "U_alex"), .init(name: "acme/web", isTeam: true, id: "T_web"), .init(name: "ghost")]
        status.latestReviews = [
            .init(login: "sam", state: .changesRequested, userID: "U_sam"),
            .init(login: "copilot-pull-request-reviewer", state: .commented, botID: "BOT_copilot"),
            .init(login: "kai", state: .approved, userID: "U_kai"),
            .init(login: "Alex", state: .commented, userID: "U_alex"),
            .init(login: "me", state: .commented, userID: "U_me"),
        ]
        let nudge = status.nudge(excluding: "me")
        #expect(nudge.userIDs == ["U_alex", "U_sam"])
        #expect(nudge.teamIDs == ["T_web"])
        #expect(nudge.botIDs == ["BOT_copilot"])
        #expect(nudge.summary == "@alex, @acme/web, @sam and @copilot-pull-request-reviewer")
    }

    @Test func with_nobody_pending_or_waiting_to_re_review_there_is_no_nudge() {
        var status = PullRequestStatus(createdAt: created)
        status.latestReviews = [.init(login: "kai", state: .approved, userID: "U_kai")]
        #expect(status.nudge(excluding: "me").isEmpty)
    }

    @Test func an_answer_is_a_review_or_comment_by_someone_else() {
        var status = PullRequestStatus(createdAt: created)
        status.latestReviews = [.init(login: "me", state: .commented, at: reference)]
        status.lastComment = .init(login: "Me", at: reference.addingTimeInterval(10))
        #expect(status.lastResponse(excluding: "me") == nil)
        status.lastComment = .init(login: "alex", at: reference.addingTimeInterval(20))
        #expect(status.lastResponse(excluding: "me") == reference.addingTimeInterval(20))
    }
}

struct FollowUpTests {
    let followUp = FollowUp(until: reference.addingTimeInterval(3600), answeredAt: reference.addingTimeInterval(-60), repository: RepositoryName(owner: "acme", name: "web"), number: 1, title: "T", url: URL(string: "https://github.com/acme/web/pull/1")!)

    @Test func a_follow_up_waits_then_reminds_if_nobody_answered() {
        #expect(followUp.outcome(lastResponse: reference.addingTimeInterval(-60), now: reference) == .waiting)
        #expect(followUp.outcome(lastResponse: reference.addingTimeInterval(-60), now: reference.addingTimeInterval(3600)) == .due)
    }

    @Test func an_answer_ends_a_follow_up_early() {
        #expect(followUp.outcome(lastResponse: reference.addingTimeInterval(30), now: reference) == .answered)
    }

    @Test func a_pull_request_not_loaded_yet_is_still_reminded_about() {
        #expect(followUp.outcome(lastResponse: nil, now: reference.addingTimeInterval(3600)) == .due)
    }
}
