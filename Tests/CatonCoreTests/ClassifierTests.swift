import Foundation
import Testing
@testable import CatonCore

struct ClassifierTests {
    let settings = ClassifierSettings()

    @Test func a_review_request_naming_the_viewer_needs_them() {
        let result = Classifier.classify(makeThread(reason: .reviewRequested), facts: makeFacts(pendingReviewRequest: .you), settings: settings)
        #expect(result.split == .needsMe)
        #expect(result.badge == .reviewYou)
    }

    @Test func a_review_request_through_a_team_goes_to_team() {
        let result = Classifier.classify(makeThread(reason: .reviewRequested), facts: makeFacts(pendingReviewRequest: .team), settings: settings)
        #expect(result.split == .team)
        #expect(result.badge == .reviewTeam)
    }

    @Test func a_review_request_before_enrichment_is_never_hidden() {
        let result = Classifier.classify(makeThread(reason: .reviewRequested), facts: nil, settings: settings)
        #expect(result.split == .needsMe)
    }

    @Test func a_pending_direct_request_wins_over_a_comment_reason() {
        let result = Classifier.classify(makeThread(reason: .comment), facts: makeFacts(pendingReviewRequest: .you), settings: settings)
        #expect(result.split == .needsMe)
    }

    @Test func a_fulfilled_review_request_moves_to_following() {
        let result = Classifier.classify(makeThread(reason: .reviewRequested), facts: makeFacts(pendingReviewRequest: nil), settings: settings)
        #expect(result.split == .following)
        #expect(result.badge == .reviewed)
    }

    @Test func team_mentions_go_to_team() {
        let result = Classifier.classify(makeThread(reason: .teamMention), facts: makeFacts(), settings: settings)
        #expect(result.split == .team)
    }

    @Test func the_viewers_own_pull_request_with_changes_requested_needs_them() {
        let facts = makeFacts(reviewDecision: .changesRequested, viewerDidAuthor: true)
        let result = Classifier.classify(makeThread(reason: .author), facts: facts, settings: settings)
        #expect(result.split == .needsMe)
        #expect(result.badge == .yourPullRequest(.changesRequested))
    }

    @Test func the_viewers_approved_green_pull_request_is_ready_to_merge() {
        let facts = makeFacts(reviewDecision: .approved, checks: .success, viewerDidAuthor: true)
        let result = Classifier.classify(makeThread(reason: .author), facts: facts, settings: settings)
        #expect(result.badge == .yourPullRequest(.readyToMerge))
    }

    @Test func the_viewers_quiet_pull_request_stays_in_following() {
        let facts = makeFacts(checks: .pending, viewerDidAuthor: true)
        let result = Classifier.classify(makeThread(reason: .author), facts: facts, settings: settings)
        #expect(result.split == .following)
    }

    @Test func a_merged_subject_outside_needs_me_is_cleared() {
        let result = Classifier.classify(makeThread(reason: .subscribed), facts: makeFacts(state: .merged), settings: settings)
        #expect(result.clearedBy == .mergedOrClosed)
    }

    @Test func a_mention_on_a_closed_subject_is_never_cleared() {
        let result = Classifier.classify(makeThread(reason: .mention), facts: makeFacts(state: .closed), settings: settings)
        #expect(result.split == .needsMe)
        #expect(result.clearedBy == nil)
    }

    @Test func an_old_mention_on_a_subject_a_bot_closed_is_not_a_new_ask() {
        var facts = makeFacts(state: .closed)
        facts.latestCommenter = SubjectActor(login: "react-native-bot", isApp: true)
        let result = Classifier.classify(makeThread(kind: .issue, reason: .mention), facts: facts, settings: settings)
        #expect(result.split == .following)
        #expect(result.clearedBy == .mergedOrClosed)
    }

    @Test func a_machine_user_named_like_a_bot_is_a_bot() {
        #expect(settings.kind(of: SubjectActor(login: "react-native-bot", isApp: false)) == .bot)
        #expect(settings.kind(of: SubjectActor(login: "k8s-ci-robot", isApp: false)) == .bot)
        #expect(settings.kind(of: SubjectActor(login: "abbot", isApp: false)) == .human)
        var listed = settings
        listed.botLogins = ["ci-helper"]
        #expect(listed.kind(of: SubjectActor(login: "CI-Helper", isApp: false)) == .bot)
    }

    @Test func a_mention_after_a_human_comment_on_a_closed_subject_still_needs_the_viewer() {
        var facts = makeFacts(state: .closed)
        facts.latestCommenter = SubjectActor(login: "maintainer", isApp: false)
        let result = Classifier.classify(makeThread(kind: .issue, reason: .mention), facts: facts, settings: settings)
        #expect(result.split == .needsMe)
    }

    @Test func a_bot_pull_request_is_routed_to_feed() {
        let facts = makeFacts(author: "dependabot", authorIsApp: true)
        let result = Classifier.classify(makeThread(reason: .comment), facts: facts, settings: settings)
        #expect(result.split == .feed)
        #expect(result.routedBy == .botPullRequests)
        #expect(result.actorKind == .bot)
    }

    @Test func a_bot_pull_request_that_requests_the_viewer_still_needs_them() {
        let facts = makeFacts(author: "dependabot", authorIsApp: true, pendingReviewRequest: .you)
        let result = Classifier.classify(makeThread(reason: .reviewRequested), facts: facts, settings: settings)
        #expect(result.split == .needsMe)
        #expect(result.routedBy == nil)
    }

    @Test func an_agent_pull_request_is_not_treated_as_a_bot() {
        let facts = makeFacts(author: "Copilot", authorIsApp: true)
        let result = Classifier.classify(makeThread(reason: .subscribed), facts: facts, settings: settings)
        #expect(result.actorKind == .agent)
        #expect(result.routedBy == nil)
    }

    @Test func a_draft_that_does_not_request_the_viewer_goes_to_feed() {
        let result = Classifier.classify(makeThread(reason: .comment), facts: makeFacts(isDraft: true), settings: settings)
        #expect(result.split == .feed)
        #expect(result.routedBy == .drafts)
    }

    @Test func a_muted_repository_is_cleared_unless_it_needs_the_viewer() {
        var muted = settings
        muted.mutedRepositories = ["acme/web"]
        let watched = Classifier.classify(makeThread(reason: .subscribed), facts: makeFacts(), settings: muted)
        let mentioned = Classifier.classify(makeThread(reason: .mention), facts: makeFacts(), settings: muted)
        #expect(watched.clearedBy == .mutedRepositories)
        #expect(mentioned.clearedBy == nil)
    }

    @Test func a_disabled_rule_does_nothing() {
        var noRules = settings
        noRules.enabledRules = []
        let result = Classifier.classify(makeThread(reason: .subscribed), facts: makeFacts(state: .merged, author: "renovate", authorIsApp: true), settings: noRules)
        #expect(result.clearedBy == nil)
        #expect(result.routedBy == nil)
    }

    @Test func watched_activity_and_ci_go_to_feed() {
        #expect(Classifier.classify(makeThread(reason: .subscribed), facts: makeFacts(), settings: settings).split == .feed)
        #expect(Classifier.classify(makeThread(reason: .ciActivity), facts: makeFacts(), settings: settings).split == .feed)
    }

    @Test func a_release_from_a_watched_repository_goes_to_feed() {
        let result = Classifier.classify(makeThread(kind: .release, number: nil, reason: .subscribed), facts: nil, settings: settings)
        #expect(result.split == .feed)
    }
}
