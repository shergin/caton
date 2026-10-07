import AppKit
import CatonCore
import SwiftUI
#if DEBUG
import BatonInspector
#endif

/// The settings window.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Caton Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, preferences: model.preferences))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    func snapshot(to url: URL) {
        guard let view = window?.contentView, window?.isVisible == true,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var preferences: Preferences

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Rules", systemImage: "line.3.horizontal.decrease.circle") { rules }
            Tab("Alerts", systemImage: "bell") { alerts }
            Tab("Account", systemImage: "person.crop.circle") { account }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutsList() }
            Tab("About", systemImage: "info.circle") { AboutView(model: model, updates: model.updates) }
            #if DEBUG
            if let graph = model.graph {
                Tab("Store", systemImage: "cylinder") { StoreInspector(graph) }
            }
            #endif
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { preferences.launchAtLogin }, set: { preferences.launchAtLogin = $0 }))
                .disabled(!preferences.canLaunchAtLogin)
            if !preferences.canLaunchAtLogin {
                Text("Available in the bundled app (scripts/bundle.sh).").font(.caption).foregroundStyle(.secondary)
            }
            if let error = preferences.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Menu bar", selection: $preferences.showsCount) {
                Text("Icon and Needs me count").tag(true)
                Text("Icon only (filled when something needs you)").tag(false)
            }
            Section {
                LabeledContent("Open the panel") {
                    HotKeyRecorder(combination: Binding(get: { preferences.hotKey }, set: { if let new = $0 { preferences.hotKey = new } }), canClear: false)
                }
                if let status = preferences.hotKeyStatus {
                    Text(status).font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Open on Needs me") {
                    HotKeyRecorder(combination: $preferences.needsMeHotKey, canClear: true)
                }
                if let status = preferences.needsMeHotKeyStatus {
                    Text(status).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("The shortcut is the one way in when macOS hides the menu bar icon. The second one opens straight into Needs me with the top item selected.")
            }
        }
        .formStyle(.grouped)
    }

    /// Rules belong to the account's inbox, so they wait for a sign-in.
    @ViewBuilder private var rules: some View {
        if let session = model.accounts.session {
            rules(session)
        } else {
            Form { Text("Sign in to set the rules for an account.").foregroundStyle(.secondary) }.formStyle(.grouped)
        }
    }

    private func rules(_ session: Session) -> some View {
        Form {
            Section {
                ForEach(Rule.allCases, id: \.self) { rule in
                    Toggle(isOn: Binding(get: { session.isEnabled(rule) }, set: { session.setEnabled(rule, $0) })) {
                        VStack(alignment: .leading) {
                            Text(rule.title)
                            Text(rule.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Rules never touch Needs me. Everything they clear is listed in Cleared, where it can be restored.")
            }
            Section {
                Toggle("Mark rule-cleared threads done on GitHub", isOn: $preferences.syncRuleClears)
            } footer: {
                Text("Off: rules hide threads on this Mac only. On: they are also marked done on github.com, after the undo window.")
            }
            Section {
                Stepper(value: Binding(get: { session.readWindowDays }, set: { session.readWindowDays = $0 }), in: 1...30) {
                    LabeledContent("Keep read threads", value: session.readWindowDays == 1 ? "1 day" : "\(session.readWindowDays) days")
                }
            } footer: {
                Text("Read threads outside Needs me leave the inbox after this long, as on github.com. Needs me keeps them until they are done.")
            }
            Section {
                if session.savedSearches.isEmpty {
                    Text("None yet. Search in the panel (/), then choose Save as split.").foregroundStyle(.secondary)
                }
                ForEach(session.savedSearches) { saved in
                    HStack {
                        TextField("Name", text: Binding(get: { saved.name }, set: { session.renameSavedSearch(saved.id, to: $0) }))
                            .labelsHidden()
                            .frame(maxWidth: 140)
                        Text(saved.query).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Delete") { model.deleteSavedSearch(saved.id) }
                    }
                }
            } header: {
                Text("Saved searches")
            } footer: {
                Text("Each shows as a split after Feed, across all four splits, on keys 5 to 9.")
            }
            LoginSection(session: session, list: .bots, title: "Bot accounts",
                         footer: "GitHub Apps and logins ending in -bot, _bot, robot or [bot] count as bots already. Add machine users named otherwise.")
            LoginSection(session: session, list: .aiReviewers, title: "AI reviewers",
                         footer: "Their reviews and comments are marked AI on the avatar.")
            LoginSection(session: session, list: .agents, title: "Coding agents",
                         footer: "Pull requests they open are marked as an agent's.")
            if !session.mutedRepositories.isEmpty {
                Section("Muted repositories") {
                    ForEach(session.mutedRepositories, id: \.self) { repository in
                        HStack {
                            Text(repository)
                            Spacer()
                            Button("Unmute") { session.unmute(repository) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var alerts: some View {
        Form {
            Toggle("Show a banner when something new needs me", isOn: $preferences.alertsEnabled)
            Stepper(value: $preferences.alertCap, in: 1...10) {
                LabeledContent("Banners per check", value: "\(preferences.alertCap), then one \"and N more\"")
            }
            .disabled(!preferences.alertsEnabled)
            Section {
                Toggle("Quiet outside working hours", isOn: $preferences.quietHours.isEnabled)
                DatePicker("Working day starts", selection: minutes(\.start), displayedComponents: .hourAndMinute)
                    .disabled(!preferences.quietHours.isEnabled)
                DatePicker("Working day ends", selection: minutes(\.end), displayedComponents: .hourAndMinute)
                    .disabled(!preferences.quietHours.isEnabled)
                Toggle("Quiet on weekends", isOn: $preferences.quietHours.weekendsQuiet)
                    .disabled(!preferences.quietHours.isEnabled)
            } footer: {
                Text("What arrives while quiet waits in the inbox without a banner. Banners never show while the panel is open, and macOS Focus silences them too.")
            }
            Section {
                Toggle("Morning digest", isOn: $preferences.digestEnabled)
            } footer: {
                Text("One banner when the working day starts: \"4 need you, 37 cleared overnight\".")
            }
            if Bundle.main.bundleIdentifier == nil {
                Text("Banners need the bundled app (scripts/bundle.sh).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var account: some View {
        Form {
            Section {
                ForEach(preferences.accounts, id: \.key) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(account.login)")
                            Text("\(account.host.name) · \(DeviceFlow.Access(scopes: account.scopes).title) · \(account.scopes.sorted().joined(separator: ", ").nonEmpty ?? "no scopes listed")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.accounts.activeKey == account.key {
                            Text("Showing").foregroundStyle(.secondary)
                            Button("Sign out", role: .destructive) { model.signOut() }
                        } else {
                            Button("Show") { model.switchAccount(to: account.key) }
                        }
                    }
                }
                Button("Add account…") { model.addAccount() }
            } header: {
                Text("Accounts")
            } footer: {
                Text("One account shows at a time, with its own rules, snoozes and Cleared log; switch from the gear menu. Tokens stay in this Mac's Keychain; signing out deletes the token and everything Caton stored for that account.")
            }
            if model.dryRun {
                Text("Dry run: nothing is sent to GitHub.").foregroundStyle(.orange)
            }
            Section("Tokens") {
                Text("Caton signs in through its GitHub OAuth App, reuses the GitHub CLI's login, or takes a classic personal access token; GitHub Enterprise accounts sign in with a token or the CLI. GitHub's notifications API rejects fine-grained personal access tokens and GitHub App tokens, so those don't work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A time-of-day binding over minutes after midnight.
    private func minutes(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(preferences.quietHours[keyPath: keyPath] * 60)) },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                preferences.quietHours[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }
}

extension Rule {
    var explanation: String {
        switch self {
        case .mergedOrClosed: "Clears threads whose pull request or issue is merged or closed."
        case .drafts: "Moves draft pull requests that do not request you to Feed."
        case .botPullRequests: "Moves pull requests opened by bots (Dependabot, Renovate…) to Feed."
        case .mutedRepositories: "Clears threads in repositories you muted here."
        }
    }
}
