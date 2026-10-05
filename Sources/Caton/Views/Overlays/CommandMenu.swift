import CatonCore
import SwiftUI

struct CommandMenu: View {
    let model: AppModel
    let close: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    /// The commands that apply to the selection, narrowed by the query.
    private var commands: [Command] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let commands = Command.menu(in: model)
        return trimmed.isEmpty ? commands : commands.filter { $0.title.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .focused($focused)
                .onSubmit(run)
                .onKeyPress(.downArrow) { index = min(index + 1, commands.count - 1); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onChange(of: query) { index = 0 }
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { offset, command in
                        HStack {
                            Text(command.title).font(.system(size: 12))
                            Spacer()
                            Text(command.keys).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(offset == index ? Color.accentColor.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            index = offset
                            run()
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 10)
        .onAppear { focused = true }
    }

    private func run() {
        guard commands.indices.contains(index) else { return }
        let command = commands[index]
        model.panel.overlay = .none
        if command.run(model) { close() }
    }
}

extension CommandMenu {
    /// The query field takes the keys; Esc closes the menu.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        guard key.special == .escape else { return .typing }
        model.panel.overlay = .none
        return .handled
    }
}
