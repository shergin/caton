import CatonCore
import SwiftUI

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
