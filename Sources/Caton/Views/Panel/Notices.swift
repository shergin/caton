import CatonCore
import SwiftUI

struct ToastStack: View {
    let toasts: [Panel.Toast]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            ForEach(toasts) { toast in
                Text(toast.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
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
            text.font(.system(size: 11)).lineLimit(2)
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
                .font(.system(size: 11))
                .help("\(Updates.upgradeCommand) installs \(release.version)")
                Button("What's new") { model.openURL(release.url) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            case .cooldown, .warning:
                EmptyView()
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
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
