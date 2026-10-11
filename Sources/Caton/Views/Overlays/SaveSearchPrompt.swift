import CatonCore
import SwiftUI

/// Names the current search before it becomes a split.
struct SaveSearchPrompt: View {
    let model: AppModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle("Save search as a split")
            Text(model.panel.searchQuery).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.saveSearch(named: name) }
            HStack {
                Spacer()
                Button("Cancel") { model.panel.overlay = .none }
                Button("Save") { model.saveSearch(named: name) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .card(width: 300)
        .onAppear { focused = true }
    }
}

extension SaveSearchPrompt {
    /// The name field takes the keys; Esc cancels.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        guard key.special == .escape else { return .typing }
        model.panel.overlay = .none
        return .handled
    }
}
