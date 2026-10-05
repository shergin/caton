import CatonCore
import SwiftUI

/// Get me to zero: each bulk clear with how many threads it would take.
struct ZeroPicker: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Get me to zero").font(.system(size: 12, weight: .semibold))
            ForEach(model.zeroOptions) { option in
                Button {
                    model.getMeToZero(option)
                } label: {
                    HStack {
                        Text(option.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(option.title).font(.system(size: 12))
                        Spacer()
                        Text("\(option.items.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(option.items.isEmpty)
                .opacity(option.items.isEmpty ? 0.45 : 1)
            }
            Text("Marks them done, after the undo window. Needs me is never cleared in bulk.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
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
