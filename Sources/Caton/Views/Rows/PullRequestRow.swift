import Baton
import CatonCore
import SwiftUI

/// One pull request: what it is and where it stands. The glyph is the inbox
/// row's own fragment, spread here; the standing line is its own view with
/// its own fragment, so a review or a check result redraws that line alone.
struct MyPullRequestRow: View {
    @Fragment("""
        fragment MyPullRequestRow_pullRequest on PullRequest {
          title
          number
          repository { nameWithOwner }
          ...PullRequestIcon_pullRequest
        }
        """)
    var pullRequest: MyPullRequestRow_pullRequest
    let standing: PullRequestStanding_pullRequest
    let followUp: FollowUp?
    /// A write waiting out its undo window: "asking again…".
    let pendingNote: String?
    let isSelected: Bool
    let onOpen: () -> Void
    let onRemind: () -> Void
    let onNudge: () -> Void
    let onReady: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            PullRequestIcon(pullRequest: pullRequest.pullRequestIcon, isUnread: true)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: "\(pullRequest.repository.nameWithOwner)#\(pullRequest.number)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let pendingNote {
                        Text(pendingNote).foregroundStyle(Color.accentColor).lineLimit(1)
                    } else if let followUp {
                        Label("remind \(followUp.until.formatted(.relative(presentation: .named)))", systemImage: "alarm")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                Text(pullRequest.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if isHovered {
                HStack(spacing: 2) {
                    if pullRequest.pullRequestIcon.isDraft {
                        RowButton(symbol: "paperplane", help: "Mark ready for review (⇧R)", action: onReady)
                    } else {
                        RowButton(symbol: "hand.wave", help: "Nudge the reviewers again (n)", action: onNudge)
                    }
                    RowButton(symbol: "alarm", help: followUp == nil ? "Remind me if nobody answers (h)" : "Change the reminder (h)", action: onRemind)
                }
            } else {
                StandingLabel(pullRequest: standing)
            }
        }
        .padding(.trailing, 7)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3) : isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Remind me", onRemind)
    }
}

/// Where a pull request stands, in a few words: "waiting on @alex · 3d".
/// The fragment is also what the app model reads to group the list and to
/// tell whether anyone answered a reminder; both read it through
/// `MyPullRequests.status`, and the reading itself is `PullRequestStanding`.
struct StandingLabel: View {
    @Fragment("""
        fragment PullRequestStanding_pullRequest on PullRequest {
          isDraft
          isInMergeQueue
          reviewDecision
          mergeable
          createdAt
          catonNudgedAt
          statusCheckRollup { state }
          reviewRequests(first: 10) {
            nodes {
              requestedReviewer {
                ... on Actor { login }
                ... on Team { slug organization { login } }
                ... on User { id }
                ... on Team { id }
                ... on Bot { id }
              }
            }
          }
          latestReviews(first: 10) { nodes { author { login ... on User { id } ... on Bot { id } } state submittedAt } }
          comments(last: 1) { nodes { author { login } createdAt } }
          timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 1) {
            nodes { ... on ReviewRequestedEvent { createdAt } }
          }
        }
        """)
    var pullRequest: PullRequestStanding_pullRequest

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let standing = PullRequestStanding.of(MyPullRequests.status(pullRequest))
            Text(standing.summary(now: context.date))
                .font(.system(size: 11, weight: standing.group == .yourMove ? .semibold : .regular))
                .foregroundStyle(standing.group == .yourMove ? Color.orange : Color.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
