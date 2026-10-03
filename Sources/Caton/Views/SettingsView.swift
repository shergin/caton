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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
        }
        .padding(20)
        .frame(width: 520, height: 420)
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
            Toggle("Show the Needs me count in the menu bar", isOn: $preferences.showsCount)
            LabeledContent("Global shortcut", value: "⌘'  (⌥⌘' when taken)")
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
            Section {
                Toggle("Quiet outside working hours", isOn: $preferences.quietHours.isEnabled)
                DatePicker("Working day starts", selection: minutes(\.start), displayedComponents: .hourAndMinute)
                    .disabled(!preferences.quietHours.isEnabled)
                DatePicker("Working day ends", selection: minutes(\.end), displayedComponents: .hourAndMinute)
                    .disabled(!preferences.quietHours.isEnabled)
                Toggle("Quiet on weekends", isOn: $preferences.quietHours.weekendsQuiet)
                    .disabled(!preferences.quietHours.isEnabled)
            } footer: {
                Text("What arrives while quiet waits in the inbox without a banner. Banners never show while the panel is open.")
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
                LabeledContent("Signed in as", value: "@\(viewer.login)")
                LabeledContent("Token scopes", value: viewer.scopes.sorted().joined(separator: ", ").nonEmpty ?? "—")
                Button("Sign out", role: .destructive) { model.signOut() }
            case .connecting:
                Text("Signing in…")
            case .signedOut:
                Text("Signed out. Sign in from the menu bar panel.")
            }
            if model.dryRun {
                Text("Dry run: nothing is sent to GitHub.").foregroundStyle(.orange)
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
