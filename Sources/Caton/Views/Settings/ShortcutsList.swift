import AppKit
import CatonCore
import SwiftUI

/// The keymap, read-only, from the command table.
struct ShortcutsList: View {
    var body: some View {
        Form {
            ForEach(Command.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(Command.keymap(group), id: \.title) { line in row(line.keys, line.title) }
                }
            }
            Section("Command menu only (⌘K)") {
                ForEach(Command.unbound) { command in Text(command.title) }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ keys: String, _ title: String) -> some View {
        LabeledContent(title) {
            Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
