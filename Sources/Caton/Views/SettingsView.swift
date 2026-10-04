import AppKit
import CatonCore
import SwiftUI

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

    private var rules: some View {
        Form {
            Section {
                ForEach(Rule.allCases, id: \.self) { rule in
                    Toggle(isOn: Binding(get: { model.isEnabled(rule) }, set: { model.setEnabled(rule, $0) })) {
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
                Stepper(value: Binding(get: { model.readWindowDays }, set: { model.readWindowDays = $0 }), in: 1...30) {
                    LabeledContent("Keep read threads", value: model.readWindowDays == 1 ? "1 day" : "\(model.readWindowDays) days")
                }
            } footer: {
                Text("Read threads outside Needs me leave the inbox after this long, as on github.com. Needs me keeps them until they are done.")
            }
            LoginSection(model: model, list: .bots, title: "Bot accounts",
                         footer: "GitHub Apps and logins ending in -bot, _bot, robot or [bot] count as bots already. Add machine users named otherwise.")
            LoginSection(model: model, list: .aiReviewers, title: "AI reviewers",
                         footer: "Their reviews and comments are marked AI on the avatar.")
            LoginSection(model: model, list: .agents, title: "Coding agents",
                         footer: "Pull requests they open are marked as an agent's.")
            if !model.mutedRepositories.isEmpty {
                Section("Muted repositories") {
                    ForEach(model.mutedRepositories, id: \.self) { repository in
                        HStack {
                            Text(repository)
                            Spacer()
                            Button("Unmute") { model.unmute(repository) }
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
            switch model.account {
            case .signedIn(let viewer):
                Section {
                    LabeledContent("Signed in as", value: "@\(viewer.login)")
                    LabeledContent("Access", value: DeviceFlow.Access(scopes: viewer.scopes).title)
                    LabeledContent("Token scopes", value: viewer.scopes.sorted().joined(separator: ", ").nonEmpty ?? "—")
                    Button("Sign out", role: .destructive) { model.signOut() }
                } footer: {
                    Text(DeviceFlow.Access(scopes: viewer.scopes).explanation + " Sign out and in again to change it. The token stays in this Mac's Keychain; signing out deletes it and everything Caton stored for the account.")
                }
            case .connecting:
                Text("Signing in…")
            case .signedOut:
                Text("Signed out. Sign in from the menu bar panel.")
            }
            if model.dryRun {
                Text("Dry run: nothing is sent to GitHub.").foregroundStyle(.orange)
            }
            Section("Tokens") {
                Text("Caton signs in through its GitHub OAuth App, reuses the GitHub CLI's login, or takes a classic personal access token. GitHub's notifications API rejects fine-grained personal access tokens and GitHub App tokens, so those don't work.")
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

/// Records a shortcut: click, press a combination with Command, Option or
/// Control; Escape cancels; the clear button removes an optional one.
struct HotKeyRecorder: View {
    @Binding var combination: HotKeyCombination?
    let canClear: Bool
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Type a shortcut…" : combination?.display ?? "None").frame(minWidth: 100)
            }
            if canClear, combination != nil, !isRecording {
                Button {
                    combination = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove the shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let key = event
            MainActor.assumeIsolated {
                if key.keyCode == 53 {
                    stop()
                } else if let new = HotKeyCombination(event: key) {
                    combination = new
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// One editable list of machine-account logins.
struct LoginSection: View {
    let model: AppModel
    let list: AppModel.LoginList
    let title: String
    let footer: String
    @State private var login = ""

    var body: some View {
        Section {
            ForEach(model.logins(list), id: \.self) { login in
                HStack {
                    Text(login)
                    Spacer()
                    Button("Remove") { model.removeLogin(login, from: list) }
                }
            }
            HStack {
                TextField("Login", text: $login).onSubmit(add)
                Button("Add", action: add).disabled(login.isEmpty)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func add() {
        model.addLogin(login, to: list)
        login = ""
    }
}

/// The keymap, read-only.
struct ShortcutsList: View {
    private let navigation: [(String, String)] = [
        ("j  k  ↓  ↑", "Move down, up"),
        ("space  ⌃F  ⌃B", "Page down, up"),
        ("⌃D  ⌃U", "Half a page down, up"),
        ("gg  G  ⌘↑  ⌘↓", "Top, bottom"),
        ("⇥  ⇧⇥", "Next, previous split"),
        ("esc", "Clear the search or selection, then close"),
    ]

    var body: some View {
        Form {
            Section("Move") {
                ForEach(navigation, id: \.0) { keys, title in row(keys, title) }
            }
            Section("Act and view") {
                ForEach(Command.all.filter { !$0.keys.isEmpty }) { command in row(command.keys, command.title) }
            }
            Section("Command menu only (⌘K)") {
                ForEach(Command.all.filter(\.keys.isEmpty)) { command in Text(command.title) }
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

/// Version, updates, this week's numbers and where Caton comes from.
struct AboutView: View {
    let model: AppModel
    let updates: Updates

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LogoImage(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Caton").font(.title2.weight(.semibold))
                        Text("Version \(updates.currentVersion)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("Check for Updates") { Task { await updates.check(userInitiated: true) } }
                            .disabled(updates.isChecking)
                        if let release = updates.available {
                            Link("Download \(release.version)", destination: release.url).font(.caption)
                        } else if let status = updates.status {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                let week = model.weekTally
                LabeledContent("Cleared by rules", value: "\(week.byRules)")
                LabeledContent("Cleared by you", value: "\(week.byYou)")
            } header: {
                Text("This week")
            } footer: {
                Text("Counted on this Mac only. Caton has no server and sends no telemetry.")
            }
            Section("Acknowledgements") {
                Text("Built on Baton, a GraphQL client for SwiftUI. Reads GitHub's notifications REST API and GraphQL API.")
                    .foregroundStyle(.secondary)
                Link("github.com/shergin/caton", destination: AppInfo.repository)
                Text("MIT License").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
