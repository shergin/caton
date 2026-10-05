import Baton
import CatonCore
import SwiftUI

/// The latest of a thread without opening it, and without marking it read:
/// GitHub marks a notification read when its page is viewed, not when the
/// API reads the subject.
struct PeekView: View {
    let item: InboxItem

    var body: some View {
        Group {
            if let number = item.thread.number, item.thread.kind == .pullRequest {
                PeekPullRequest(peek: PeekPullRequestQuery(owner: item.thread.repository.owner, name: item.thread.repository.name, number: number))
            } else if let number = item.thread.number, item.thread.kind == .issue {
                PeekIssue(peek: PeekIssueQuery(owner: item.thread.repository.owner, name: item.thread.repository.name, number: number))
            } else {
                Text("Nothing to peek at for a \(item.thread.kind.title.lowercased()). Press ⏎ to open it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 10)
    }
}

extension PeekView {
    /// Esc, space or `p` closes the peek. Any other key closes it and does
    /// its job on the row: ⏎ opens it, `e` marks it done.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        model.panel.overlay = .none
        let closesOnly = key.special == .escape || (key.shortcutModifiers.isEmpty && [" ", "p"].contains(key.characters))
        return closesOnly ? .handled : .passed
    }
}

/// A pull request's description, latest comment and latest reviews. The view
/// owns its query: the store answers at once for a subject seen before, and
/// the network fills in the rest.
struct PeekPullRequest: View {
    @Query("""
        query PeekPullRequestQuery($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              title
              bodyText
              author { login }
              comments(last: 1) {
                totalCount
                nodes { author { login } bodyText createdAt }
              }
              latestReviews(first: 5) {
                nodes { author { login } state }
              }
            }
          }
        }
        """, fetchPolicy: .storeOrNetwork)
    var peek: PeekPullRequestQuery

    var body: some View {
        switch peek.phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .failed(let error):
            Text(String(describing: error)).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
        case .ready(let data):
            if let pullRequest = data.repository?.pullRequest {
                VStack(alignment: .leading, spacing: 8) {
                    PeekHeader(title: pullRequest.title, author: pullRequest.author?.login)
                    PeekBody(text: pullRequest.bodyText)
                    if let reviews = pullRequest.latestReviews?.nodes, !reviews.isEmpty {
                        Text(reviews.map { "\($0.author?.login ?? "ghost") \($0.state.lowercased().replacingOccurrences(of: "_", with: " "))" }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let comment = pullRequest.comments.nodes?.last {
                        PeekComment(author: comment.author?.login, text: comment.bodyText, createdAt: comment.createdAt, total: pullRequest.comments.totalCount)
                    }
                    PeekFooter()
                }
            } else {
                Text("This pull request is gone or out of reach.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct PeekIssue: View {
    @Query("""
        query PeekIssueQuery($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            issue(number: $number) {
              title
              bodyText
              author { login }
              comments(last: 1) {
                totalCount
                nodes { author { login } bodyText createdAt }
              }
            }
          }
        }
        """, fetchPolicy: .storeOrNetwork)
    var peek: PeekIssueQuery

    var body: some View {
        switch peek.phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .failed(let error):
            Text(String(describing: error)).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
        case .ready(let data):
            if let issue = data.repository?.issue {
                VStack(alignment: .leading, spacing: 8) {
                    PeekHeader(title: issue.title, author: issue.author?.login)
                    PeekBody(text: issue.bodyText)
                    if let comment = issue.comments.nodes?.last {
                        PeekComment(author: comment.author?.login, text: comment.bodyText, createdAt: comment.createdAt, total: issue.comments.totalCount)
                    }
                    PeekFooter()
                }
            } else {
                Text("This issue is gone or out of reach.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct PeekHeader: View {
    let title: String
    let author: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            if let author { Text("by \(author)").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

struct PeekBody: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text.count > 400 ? String(text.prefix(400)) + "…" : text)
                .font(.system(size: 11))
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PeekComment: View {
    let author: String?
    let text: String
    let createdAt: String
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            HStack {
                Text("Latest of \(total) comments · \(author ?? "ghost")").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let date = try? Date(createdAt, strategy: .iso8601) {
                    Text(Age.short(Date.now.timeIntervalSince(date))).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text(text.count > 300 ? String(text.prefix(300)) + "…" : text)
                .font(.system(size: 11))
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PeekFooter: View {
    var body: some View {
        Text("⏎ open · e done · any other key closes").font(.system(size: 10)).foregroundStyle(.tertiary)
    }
}

/// The once-per-account summary after the first sync, and the one choice
/// that matters: whether rule clears reach GitHub.
struct WelcomeView: View {
    let model: AppModel
    let welcome: AppModel.Welcome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogoImage(size: 36)
            Text("Of \(welcome.total) notifications, \(welcome.needsMe == 1 ? "1 needs" : "\(welcome.needsMe) need") you.")
                .font(.system(size: 14, weight: .semibold))
            let cleared = welcome.cleared.values.reduce(0, +)
            if cleared > 0 {
                Text("Rules cleared \(cleared): " + Rule.allCases.compactMap { rule in welcome.cleared[rule].map { "\(rule.title.lowercased()) \($0)" } }.joined(separator: ", ") + ". They are in Cleared, where each can be restored.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Team requests, threads you follow and watched activity are in their own tabs; only Needs me counts in the menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Hint(key: "e", label: "done")
                Hint(key: "h", label: "snooze")
                Hint(key: "⇥", label: "next tab")
                Hint(key: "⌘K", label: "everything")
            }
            Divider()
            Text("Should rules also mark what they clear as done on GitHub?").font(.system(size: 12))
            HStack {
                Button("Keep on this Mac") { model.finishWelcome(syncRuleClears: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Mark done on GitHub") { model.finishWelcome(syncRuleClears: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
    }
}

extension WelcomeView {
    /// ⏎ or Esc keeps rule clears on this Mac; the other choice takes a click.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        if key.special == .escape || key.special == .enter { model.finishWelcome(syncRuleClears: false) }
        return .handled
    }
}
