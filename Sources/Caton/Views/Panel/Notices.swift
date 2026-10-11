import CatonCore
import SwiftUI

/// A band across the top while the inbox is not the account's as GitHub
/// sees it: the practice inbox, or a dry run.
struct ModeStrip: View {
    let model: AppModel

    var body: some View {
        if model.isPractice {
            strip("Practice inbox · nothing here reaches GitHub", color: .accentColor) {
                Button("Leave") { model.exitPractice() }
                    .buttonStyle(.plain)
                    .font(Theme.Font.detailEmphasized)
                    .help("Back to your inbox")
            }
        } else if model.dryRun {
            strip("Dry run · changes stay on this Mac", color: .orange) { EmptyView() }
        }
    }

    private func strip<Trailing: View>(_ message: String, color: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(message).font(Theme.Font.detail).lineLimit(1)
            Spacer()
            trailing()
        }
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Spacing.margin)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
    }
}

struct ToastStack: View {
    let toasts: [Panel.Toast]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            ForEach(toasts) { toast in
                Text(toast.message)
                    .font(Theme.Font.detail)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85), value: toasts)
    }
}

/// One line above the footer: an error, a rate-limit cooldown, a warning
/// or an available update, whichever matters most.
struct StatusStrip: View {
    let message: AppModel.StatusMessage
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10))
            text.font(Theme.Font.detail).lineLimit(2)
            Spacer()
            switch message {
            case .error:
                Button(action: model.dismissError) { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain)
                    .help("Dismiss")
            case .update(let release):
                Button("Copy command") {
                    model.updates.copyUpgradeCommand()
                    model.panel.toast("Copied \(Updates.upgradeCommand)")
                }
                .buttonStyle(.link)
                .font(Theme.Font.detail)
                .help("\(Updates.upgradeCommand) installs \(release.version)")
                Button("What's new") { model.openURL(release.url) }
                    .buttonStyle(.link)
                    .font(Theme.Font.detail)
            case .cooldown, .warning:
                EmptyView()
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Spacing.margin)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
    }

    @ViewBuilder private var text: some View {
        switch message {
        case .error(let message), .warning(let message):
            Text(message)
        case .cooldown(let until):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(until.timeIntervalSince(context.date)))
                Text("GitHub's rate limit: paused, resuming in \(seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s")")
            }
        case .update(let release):
            Text("Caton \(release.version) is available")
        }
    }

    private var symbol: String {
        switch message {
        case .error: "exclamationmark.triangle.fill"
        case .cooldown: "hourglass"
        case .warning: "exclamationmark.circle"
        case .update: "arrow.down.circle"
        }
    }

    private var color: Color {
        switch message {
        case .error: .orange
        case .cooldown, .warning: .secondary
        case .update: .accentColor
        }
    }
}
