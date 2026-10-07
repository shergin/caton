import Baton
import CatonCore
import SwiftUI

/// A pull request's type-and-state glyph. It reads only these fields, so a
/// merge re-renders this glyph and nothing else in the row.
struct PullRequestIcon: View {
    @Fragment("""
        fragment PullRequestIcon_pullRequest on PullRequest {
          state
          isDraft
          isInMergeQueue
        }
        """)
    var pullRequest: PullRequestIcon_pullRequest
    var isUnread: Bool

    var body: some View {
        let (symbol, color): (String, Color) = switch (pullRequest.state, pullRequest.isDraft, pullRequest.isInMergeQueue) {
        case (.MERGED, _, _): ("arrow.triangle.merge", .purple)
        case (.CLOSED, _, _): ("arrow.triangle.pull", .red)
        case (_, _, true): ("arrow.triangle.merge", .orange)
        case (_, true, _): ("arrow.triangle.pull", .secondary)
        default: ("arrow.triangle.pull", .green)
        }
        SubjectGlyph(symbol: symbol, color: color, isUnread: isUnread)
    }
}

/// An issue's state glyph.
struct IssueIcon: View {
    @Fragment("""
        fragment IssueIcon_issue on Issue {
          state
          stateReason
        }
        """)
    var issue: IssueIcon_issue
    var isUnread: Bool

    var body: some View {
        let (symbol, color): (String, Color) = switch (issue.state, issue.stateReason) {
        case (.CLOSED, .NOT_PLANNED?), (.CLOSED, .DUPLICATE?): ("slash.circle", .secondary)
        case (.CLOSED, _): ("checkmark.circle", .purple)
        default: ("smallcircle.filled.circle", .green)
        }
        SubjectGlyph(symbol: symbol, color: color, isUnread: isUnread)
    }
}

/// CI and author for a pull request row.
struct PullRequestSignals: View {
    @Fragment("""
        fragment PullRequestSignals_pullRequest on PullRequest {
          state
          statusCheckRollup { state }
          author { login avatarUrl }
        }
        """)
    var pullRequest: PullRequestSignals_pullRequest
    var actorKind: ActorKind?

    var body: some View {
        HStack(spacing: 4) {
            if pullRequest.state == .OPEN, let checks = pullRequest.statusCheckRollup?.state {
                ChecksGlyph(state: checks)
            }
            if let author = pullRequest.author {
                Avatar(url: author.avatarUrl, login: author.login, kind: actorKind)
            }
        }
    }
}

/// The author of an issue row.
struct IssueSignals: View {
    @Fragment("""
        fragment IssueSignals_issue on Issue {
          author { login avatarUrl }
        }
        """)
    var issue: IssueSignals_issue
    var actorKind: ActorKind?

    var body: some View {
        if let author = issue.author {
            Avatar(url: author.avatarUrl, login: author.login, kind: actorKind)
        }
    }
}

/// A subject's glyph drawn from plain facts rather than a Baton record.
struct FactsGlyph: View {
    let facts: SubjectFacts
    let kind: SubjectKind
    let isUnread: Bool

    var body: some View {
        let (symbol, color): (String, Color) = switch (kind, facts.state) {
        case (.pullRequest, .merged): ("arrow.triangle.merge", .purple)
        case (.pullRequest, .closed): ("arrow.triangle.pull", .red)
        case (.pullRequest, .open): facts.isDraft ? ("arrow.triangle.pull", .secondary) : ("arrow.triangle.pull", .green)
        case (_, .open): ("smallcircle.filled.circle", .green)
        default: ("checkmark.circle", .purple)
        }
        SubjectGlyph(symbol: symbol, color: color, isUnread: isUnread)
    }
}

/// The glyph for a thread whose subject is not an issue or pull request, or
/// is not loaded yet.
struct KindGlyph: View {
    let kind: SubjectKind
    let isUnread: Bool

    var body: some View {
        let symbol = switch kind {
        case .pullRequest: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        case .release: "tag"
        case .discussion: "bubble.left.and.bubble.right"
        case .commit: "point.3.filled.connected.trianglepath.dotted"
        case .checkSuite, .workflowRun: "gearshape.2"
        case .securityAlert: "exclamationmark.shield"
        case .invitation: "envelope"
        case .other: "bell"
        }
        SubjectGlyph(symbol: symbol, color: .secondary, isUnread: isUnread)
    }
}

struct SubjectGlyph: View {
    let symbol: String
    let color: Color
    let isUnread: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .opacity(isUnread ? 1 : 0.55)
            .frame(width: 16, height: 16)
    }
}

struct ChecksGlyph: View {
    let state: StatusState

    var body: some View {
        switch state {
        case .SUCCESS:
            Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 9, weight: .bold))
                .help("Checks passed")
        case .FAILURE, .ERROR:
            Image(systemName: "xmark").foregroundStyle(.red).font(.system(size: 9, weight: .bold))
                .help("Checks failed")
        default:
            Circle().fill(.yellow).frame(width: 6, height: 6)
                .help("Checks running")
        }
    }
}

struct Avatar: View {
    let url: URL?
    let login: String
    let kind: ActorKind?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: 14, height: 14)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if let symbol = kind?.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 6, weight: .bold))
                    .padding(1)
                    .background(.background, in: Circle())
                    .offset(x: 3, y: 3)
            }
        }
        .help(kind.map { "\(login) · \($0.title)" } ?? login)
    }
}

extension ActorKind {
    /// The badge drawn on an avatar. The spoken name is `title`.
    var symbol: String? {
        switch self {
        case .human: nil
        case .bot: "gearshape.fill"
        case .aiReviewer: "sparkles"
        case .agent: "cpu"
        }
    }
}
