import CatonCore
import SwiftUI

/// "Why is this here?": the classifier's reasoning for the selected thread.
struct WhyCard: View {
    let item: InboxItem
    let actor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle("Why it's in \(item.classification.split.title)")
            Text(item.classification.because).font(Theme.Font.body).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                fact("GitHub's reason", item.thread.reason.rawValue.replacingOccurrences(of: "_", with: " "))
                fact("Label", item.classification.badge.title)
                if let rule = item.classification.routedBy { fact("Rule", rule.title) }
                if let actor { fact("Opened by", actor + (item.classification.actorKind.map { $0 == .human ? "" : " (\($0.title))" } ?? "")) }
                if let note = item.resurfacing?.note { fact("Back because", String(note.dropFirst("back: ".count))) }
            }
            CardNote("Wrong? Mute the repository, mark an account as a bot or turn the rule off in Settings.")
        }
        .card(width: 320)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
        .font(Theme.Font.detail)
    }
}

extension WhyCard {
    /// Any key closes it.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        model.panel.overlay = .none
        return .handled
    }
}
