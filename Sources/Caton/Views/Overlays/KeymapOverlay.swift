import CatonCore
import SwiftUI

/// Every bound key, from the command table, by group: two columns when
/// the panel is wide enough, else one that scrolls.
struct KeymapOverlay: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keys").font(.system(size: 13, weight: .semibold))
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
            Text("Any key closes. ⌘K lists the rest.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 10)
    }

    private func column(_ groups: [Command.Group]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.self) { group in
                Text(group.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(Command.keymap(group, keys: 2), id: \.title) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.keys).font(.system(size: 10, design: .monospaced)).frame(width: 64, alignment: .leading)
                        Text(line.title).font(.system(size: 10)).lineLimit(1).frame(width: 170, alignment: .leading)
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
