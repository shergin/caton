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
    /// The subject's state and who opened it, for VoiceOver.
    let spokenState: String
    /// State to draw from when Baton has no record: the practice inbox.
    var fallback: SubjectFacts? = nil
    let onOpen: () -> Void
    let onToggleCheck: () -> Void
    let onDone: () -> Void
    let onSnooze: () -> Void
    let onUnsubscribe: () -> Void

    @State private var isHovered = false
    @State private var isIconHovered = false

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
            .onHover { isIconHovered = $0 }
            .help(isChecked ? "Deselect" : "Select for bulk actions (x)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(showsRepository ? item.thread.reference : item.thread.number.map { "#\($0)" } ?? item.thread.kind.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = item.resurfacing?.note {
                        Text(note).foregroundStyle(.orange).lineLimit(1)
                    } else if case .reviewRequest = item.id {
                        Text("no notification").foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .font(Theme.Font.detail)
                Text(item.thread.title)
                    .font(item.isUnread ? Theme.Font.titleEmphasized : Theme.Font.title)
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
                    HStack(spacing: 5) {
                        signals
                        Age(date: item.thread.updatedAt, emphasized: showsWaiting)
                    }
                }
            }
        }
        .rowChrome(isSelected: isSelected, isHovered: isHovered)
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(item.isUnread ? "Unread" : "Read")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Done", onDone)
        .accessibilityAction(named: "Snooze", onSnooze)
        .accessibilityAction(named: "Unsubscribe", onUnsubscribe)
        .accessibilityAction(named: isChecked ? "Deselect" : "Select", onToggleCheck)
    }

    /// Title, reference, label, state and author, age, and why it is back.
    private var spokenLabel: String {
        var parts = [item.thread.title, item.thread.reference, item.classification.badge.title]
        if !spokenState.isEmpty { parts.append(spokenState) }
        parts.append("updated \(item.thread.updatedAt.formatted(.relative(presentation: .named)))")
        if let note = item.resurfacing?.note { parts.append(note.replacingOccurrences(of: "back:", with: "back because of")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var glyph: some View {
        if isChecked {
            Image(systemName: "checkmark.square.fill").foregroundStyle(Color.accentColor)
        } else if isIconHovered {
            // Hovering the icon offers it as a checkbox.
            Image(systemName: "square").foregroundStyle(.secondary)
        } else if let pullRequest = lenses.pullRequestIcon {
            PullRequestIcon(pullRequest: pullRequest, isUnread: item.isUnread)
        } else if let issue = lenses.issueIcon {
            IssueIcon(issue: issue, isUnread: item.isUnread)
        } else if let fallback {
            FactsGlyph(facts: fallback, kind: item.thread.kind, isUnread: item.isUnread)
        } else {
            KindGlyph(kind: item.thread.kind, isUnread: item.isUnread)
        }
    }

    @ViewBuilder private var signals: some View {
        if let pullRequest = lenses.pullRequestSignals {
            PullRequestSignals(pullRequest: pullRequest, actorKind: item.classification.actorKind)
        } else if let issue = lenses.issueSignals {
            IssueSignals(issue: issue, actorKind: item.classification.actorKind)
        } else if let fallback {
            HStack(spacing: 5) {
                if fallback.state == .open, let checks = fallback.checks {
                    ChecksGlyph(state: checks == .success ? .SUCCESS : checks == .failure ? .FAILURE : .PENDING)
                }
                if let author = fallback.author {
                    Avatar(url: nil, login: author.login, kind: item.classification.actorKind)
                }
            }
        }
    }
}

/// The ownership label: why the thread is where it is, in a word or two.
/// Plain text; it stands out only when it is addressed to the viewer.
struct BadgeLabel: View {
    let classification: Classification

    var body: some View {
        let badge = classification.badge
        Text(classification.routedBy == .drafts ? "Draft" : badge.title)
            .font(badge.isDirect ? Theme.Font.detailEmphasized : Theme.Font.detail)
            .foregroundStyle(badge.isDirect ? .primary : .secondary)
            .lineLimit(1)
            .fixedSize()
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
