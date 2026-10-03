import Baton
import CatonCore
import SwiftUI

/// One thread. The REST fields come in as a value; the subject's state comes
/// in as Baton lenses, so a merge or a CI result re-renders this row alone.
struct ThreadRow: View {
    let item: InboxItem
    let isSelected: Bool
    let isChecked: Bool
    let showsWaiting: Bool
    /// Whether line one names the repository; under a repository header it does not.
    let showsRepository: Bool
    let lenses: SubjectStore.Lenses
    let onOpen: () -> Void
    let onToggleCheck: () -> Void
    let onDone: () -> Void
    let onSnooze: () -> Void
    let onUnsubscribe: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCheck) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.isUnread ? Color.accentColor : .clear)
                        .frame(width: 6, height: 6)
                    glyph.frame(width: 16)
                }
                .frame(width: 30, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isChecked ? "Deselect" : "Select for bulk actions (x)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(showsRepository ? item.thread.reference : item.thread.number.map { "#\($0)" } ?? item.thread.kind.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = item.resurfacing?.note {
                        Text(note).foregroundStyle(.orange).lineLimit(1)
                    } else if item.id.hasPrefix(SubjectStore.reviewRequestPrefix) {
                        Text("no notification").foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                Text(item.thread.title)
                    .font(.system(size: 13, weight: item.isUnread ? .semibold : .regular))
                    .foregroundStyle(item.isUnread ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            if isHovered {
                HStack(spacing: 2) {
                    RowButton(symbol: "checkmark", help: "Done (e)", action: onDone)
                    RowButton(symbol: "moon.zzz", help: "Snooze (h)", action: onSnooze)
                    RowButton(symbol: "bell.slash", help: "Unsubscribe (u)", action: onUnsubscribe)
                }
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    BadgeLabel(classification: item.classification)
                    HStack(spacing: 4) {
                        signals
                        Age(date: item.thread.updatedAt, emphasized: showsWaiting)
                    }
                }
            }
        }
        .padding(.trailing, 7)
        .frame(height: 46)
        // A menu item's highlight: inset, rounded.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3) : isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.thread.title), \(item.thread.reference), \(item.classification.badge.title)")
        .accessibilityValue(item.isUnread ? "Unread" : "Read")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var glyph: some View {
        if isChecked {
            Image(systemName: "checkmark.square.fill").foregroundStyle(Color.accentColor)
        } else if let pullRequest = lenses.pullRequestIcon {
            PullRequestIcon(pullRequest: pullRequest, isUnread: item.isUnread)
        } else if let issue = lenses.issueIcon {
            IssueIcon(issue: issue, isUnread: item.isUnread)
        } else {
            KindGlyph(kind: item.thread.kind, isUnread: item.isUnread)
        }
    }

    @ViewBuilder private var signals: some View {
        if let pullRequest = lenses.pullRequestSignals {
            PullRequestSignals(pullRequest: pullRequest, actorKind: item.classification.actorKind)
        } else if let issue = lenses.issueSignals {
            IssueSignals(issue: issue, actorKind: item.classification.actorKind)
        }
    }
}

struct BadgeLabel: View {
    let classification: Classification

    var body: some View {
        let badge = classification.badge
        Text(classification.routedBy == .drafts ? "Draft" : badge.title)
            .font(.system(size: 10, weight: badge.isDirect ? .semibold : .regular))
            .foregroundStyle(badge.isDirect ? Color.green : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(badge.isDirect ? Color.green.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
            .fixedSize()
    }
}

struct Age: View {
    let date: Date
    let emphasized: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let seconds = context.date.timeIntervalSince(date)
            Text(emphasized && seconds > 4 * 3600 ? "waiting \(Self.short(seconds))" : Self.short(seconds))
                .font(.system(size: 11))
                .foregroundStyle(emphasized && seconds > 24 * 3600 ? .orange : .secondary)
                .fixedSize()
        }
    }

    static func short(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "now"
        case ..<3600: "\(Int(seconds / 60))m"
        case ..<86400: "\(Int(seconds / 3600))h"
        default: "\(Int(seconds / 86400))d"
        }
    }
}

struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

extension SubjectKind {
    var title: String {
        switch self {
        case .pullRequest: "Pull request"
        case .issue: "Issue"
        case .release: "Release"
        case .discussion: "Discussion"
        case .commit: "Commit"
        case .checkSuite, .workflowRun: "Workflow"
        case .securityAlert: "Security alert"
        case .invitation: "Invitation"
        case .other: "Notification"
        }
    }
}
