import CatonCore
import SwiftUI

/// The verbs that apply to the selection, from the command table, each a
/// key cap that runs on a click; ⌘K for the rest; and the settings menu.
struct PanelFooter: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if model.panel.checked.isEmpty {
                hints(limit: 3)
            } else {
                Text("\(model.panel.checked.count) selected")
                    .font(Theme.Font.detailEmphasized)
                    .foregroundStyle(Color.accentColor)
                hints(limit: 2)
                hint("esc", "clear") { _ = model.panel.unwind() }
            }
            hint("⌘K", "commands") { model.panel.overlay = .commands }
            Spacer()
            SettingsMenu(model: model)
        }
        .padding(.horizontal, Theme.Spacing.margin)
        .padding(.vertical, 7)
    }

    private func hints(limit: Int) -> some View {
        ForEach(Command.hints(in: model, limit: limit), id: \.id) { command in
            hint(command.bindings.first?.label ?? "", command.hint ?? command.title) {
                if command.run(model) { close() }
            }
        }
    }

    private func hint(_ key: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { KeyHint(key: key, label: label) }
            .buttonStyle(.plain)
            .help(label.capitalized)
    }
}

struct SettingsMenu: View {
    @Bindable var model: AppModel

    /// `@octocat`, or `@octocat on github.acme.com`.
    static func name(of account: Viewer) -> String {
        account.host.isDotCom ? "@\(account.login)" : "@\(account.login) on \(account.host.name)"
    }

    var body: some View {
        Menu {
            if let inbox = model.inbox {
                Section("Rules") {
                    ForEach(Rule.allCases, id: \.self) { rule in
                        Toggle(rule.title, isOn: Binding(get: { inbox.isEnabled(rule) }, set: { inbox.setEnabled(rule, $0) }))
                    }
                    Toggle("Mark rule-cleared threads done on GitHub", isOn: Binding(get: { model.preferences.syncRuleClears }, set: { model.preferences.syncRuleClears = $0 }))
                }
                if !inbox.mutedRepositories.isEmpty {
                    Menu("Muted repositories") {
                        ForEach(inbox.mutedRepositories, id: \.self) { repository in
                            Button("Unmute \(repository)") { inbox.unmute(repository) }
                        }
                    }
                }
            }
            Section("View") {
                Toggle("Group by repository", isOn: Bindable(model.panel).groupByRepository)
                Toggle("Unread only", isOn: Bindable(model.panel).unreadOnly)
                Button(model.preferences.detached ? "Back to the menu bar" : "Open in a window") {
                    model.preferences.detached ? model.attach?() : model.detach?()
                }
            }
            Section("Accounts") {
                ForEach(model.accounts.all, id: \.key) { account in
                    Toggle(Self.name(of: account), isOn: Binding(
                        get: { model.accounts.activeKey == account.key },
                        set: { if $0 { model.switchAccount(to: account.key) } }
                    ))
                }
                Button("Add account…") { model.addAccount() }
                if case .signedIn(let viewer) = model.account {
                    Button("Sign out @\(viewer.login)") { model.signOut() }
                }
            }
            Divider()
            Button("Settings…") { model.openSettings?() }
            Button("Refresh") { model.inbox?.refresh() }
            Button("Quit Caton") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rules, view, accounts and settings")
    }
}
