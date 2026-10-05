import CatonCore
import SwiftUI

/// The verbs that apply to the selection, from the command table, and the
/// settings menu.
struct PanelFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.panel.checked.isEmpty {
                hints(limit: 4)
                Hint(key: "?", label: "keys")
            } else {
                Text("\(model.panel.checked.count) selected").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                hints(limit: 2)
                Hint(key: "esc", label: "clear")
            }
            Spacer()
            SettingsMenu(model: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func hints(limit: Int) -> some View {
        ForEach(Command.hints(in: model, limit: limit), id: \.label) { hint in
            Hint(key: hint.key, label: hint.label)
        }
    }
}

struct Hint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
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
            Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
