import CatonCore
import SwiftUI

/// Get me to zero: each bulk clear with how many threads it would take.
struct ZeroPicker: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            CardTitle("Get me to zero")
            Text("In \(model.zeroScope)").font(Theme.Font.detail).foregroundStyle(.secondary).padding(.bottom, 6)
            ForEach(model.zeroOptions) { option in
                MenuRow(key: option.key, title: option.title, isEnabled: !option.items.isEmpty) {
                    model.getMeToZero(option)
                } trailing: {
                    Text("\(option.items.count)").font(Theme.Font.count).foregroundStyle(.secondary)
                }
            }
            CardNote("Marks them done, after the undo window. Needs me is never cleared in bulk.")
                .padding(.horizontal, 6)
                .padding(.top, 8)
        }
        .card(width: 300, padding: 10)
    }
}

extension ZeroPicker {
    /// A digit runs its clear.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        if key.special == .escape {
            model.panel.overlay = .none
        } else if !key.isRepeat, let option = model.zeroOptions.first(where: { $0.key == key.characters }) {
            model.getMeToZero(option)
        }
        return .handled
    }
}
