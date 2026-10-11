import CatonCore
import SwiftUI

/// ⌘K: every command that applies now, narrowed as the user types.
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
            HStack(spacing: 8) {
                Image(systemName: "command").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Type a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.title)
                    .focused($focused)
                    .onSubmit(run)
                    .onKeyPress(.downArrow) { index = min(index + 1, commands.count - 1); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onChange(of: query) { index = 0 }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { offset, command in
                            HStack {
                                Text(command.title).font(Theme.Font.body)
                                Spacer()
                                Text(command.keys).font(Theme.Font.detail).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .frame(minHeight: 26)
                            .background(offset == index ? Theme.Fill.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                index = offset
                                run()
                            }
                            .id(offset)
                        }
                        if commands.isEmpty {
                            Text("No command matches").font(Theme.Font.body).foregroundStyle(.tertiary).padding(8)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
                .onChange(of: index) { _, index in proxy.scrollTo(index) }
            }
        }
        .card(width: 340, padding: 0)
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
