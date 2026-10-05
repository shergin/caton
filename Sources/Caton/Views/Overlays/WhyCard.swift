import CatonCore
import SwiftUI

/// "Why is this here?": the classifier's reasoning for the selected thread.
struct WhyCard: View {
    let item: InboxItem
    let actor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why it's in \(item.classification.split.title)").font(.system(size: 12, weight: .semibold))
            Text(item.classification.because).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                fact("GitHub's reason", item.thread.reason.rawValue.replacingOccurrences(of: "_", with: " "))
                fact("Label", item.classification.badge.title)
                if let rule = item.classification.routedBy { fact("Rule", rule.title) }
                if let actor { fact("Opened by", actor + (item.classification.actorKind.map { $0 == .human ? "" : " (\($0.title))" } ?? "")) }
                if let note = item.resurfacing?.note { fact("Back because", String(note.dropFirst("back: ".count))) }
            }
            Text("Wrong? Mute the repository, mark an account as a bot or turn the rule off in Settings.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
        .font(.system(size: 11))
    }
}

extension WhyCard {
    /// Any key closes it.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        model.panel.overlay = .none
        return .handled
    }
}
