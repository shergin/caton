import CatonCore
import SwiftUI

/// Every bound key, from the command table, by group: two columns when
/// the panel is wide enough, else one that scrolls.
struct KeymapOverlay: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle("Keys")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    column([.act, .view, .app])
                    column([.move, .go])
                }
                ScrollView {
                    column(Command.Group.allCases)
                }
                .frame(maxHeight: 400)
            }
            CardNote("Any key closes. ⌘K lists the rest.")
        }
        .card()
    }

    private func column(_ groups: [Command.Group]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.self) { group in
                Text(group.title).font(Theme.Font.sectionHeader).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(Command.keymap(group, keys: 2), id: \.title) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.keys).font(Theme.Font.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(line.title).font(Theme.Font.caption).lineLimit(1).frame(width: 170, alignment: .leading)
                    }
                }
            }
        }
    }
}

extension KeymapOverlay {
    /// Any key closes it.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        model.panel.overlay = .none
        return .handled
    }
}
