import CatonCore
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    let close: () -> Void

    var body: some View {
        Group {
            switch model.account {
            case _ where model.isPractice:
                InboxView(model: model, close: close)
            case .signedIn:
                InboxView(model: model, close: close)
                    .environment(\.baton, model.graph)
            case .signedOut, .connecting:
                SignInView(model: model)
            }
        }
        // The glass behind draws the background and the edge; the content
        // takes whatever size the panel has.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

struct InboxView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    private var panel: Bindable<Panel> { Bindable(model.panel) }
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.panel.isSearching || !model.panel.searchQuery.isEmpty { searchField }
            Divider().opacity(0.5)
            ZStack(alignment: .bottom) {
                content
                ToastStack(toasts: model.panel.toasts)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            .overlay { overlay }
            Divider().opacity(0.5)
            if let status = model.statusMessage { StatusStrip(message: status, model: model) }
            footer
        }
        .onChange(of: model.panel.isSearching) { _, searching in searchFocused = searching }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LogoImage(size: 16)
                Text("Caton").font(.system(size: 13, weight: .semibold))
                if model.isPractice {
                    Text("PRACTICE").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor)
                    Button("Leave") { model.exitPractice() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help("Back to your inbox; nothing you did here reached GitHub")
                } else if model.dryRun {
                    Text("DRY RUN").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                }
                if model.inbox?.isSyncing == true { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    model.preferences.detached ? model.attach?() : model.detach?()
                } label: {
                    Image(systemName: model.preferences.detached ? "menubar.arrow.up.rectangle" : "macwindow")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(model.preferences.detached ? "Back under the menu bar icon" : "Open in a window")
                Button { model.panel.overlay = .commands } label: {
                    Text("⌘K").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Commands")
            }
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Split.allCases, id: \.self) { split in
                            SectionTab(title: split.title, count: model.panel.count(.split(split)), isSelected: model.panel.section == .split(split), isPrimary: split == .needsMe) {
                                model.panel.show(.split(split))
                            }
                        }
                        // Saved searches, as splits of their own.
                        ForEach(model.inbox?.savedSearches ?? []) { saved in savedTab(saved) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                Spacer(minLength: 0)
                Menu {
                    Button("My pull requests (\(model.panel.count(.myPullRequests)))") { model.panel.show(.myPullRequests) }
                    Button("Snoozed (\(model.panel.count(.snoozed)))") { model.panel.show(.snoozed) }
                    Button("Later (\(model.panel.count(.later)))") { model.panel.show(.later) }
                    Button("Cleared (\(model.panel.count(.cleared)))") { model.panel.show(.cleared) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("My pull requests, Snoozed, Later and Cleared")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func savedTab(_ saved: SavedSearch) -> some View {
        SectionTab(title: saved.name, count: model.panel.count(.saved(saved.id)), isSelected: model.panel.section == .saved(saved.id), isPrimary: false) {
            model.panel.show(.saved(saved.id))
        }
        .contextMenu {
            Button("Delete \(saved.name)") { model.deleteSavedSearch(saved.id) }
        }
        .help(saved.query)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Filter by title or repository", text: panel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { model.panel.isSearching = false }
                .onKeyPress(.tab) {
                    model.panel.isSearching = false
                    return .handled
                }
                .onExitCommand {
                    model.panel.searchQuery = ""
                    model.panel.isSearching = false
                }
            if !model.panel.searchQuery.isEmpty, case .split = model.panel.section {
                Button("Save as split") { model.beginSavingSearch() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: List

    @ViewBuilder private var content: some View {
        switch model.panel.section {
        case .cleared:
            ClearedList(model: model)
        case .myPullRequests:
            if model.isPractice {
                Text("Your own pull requests show here when you are signed in.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MyPullRequestsView(pullRequests: .init(), model: model)
            }
        default:
            let rows = model.panel.rows
            if rows.isEmpty {
                EmptyState(model: model, filtered: !model.panel.searchQuery.isEmpty || model.panel.unreadOnly)
            } else {
                list(rows)
            }
        }
    }

    private func list(_ rows: [ListRow]) -> some View {
        let waiting = model.panel.section == .split(.needsMe)
        // Threads inside a bot's bundle come from many repositories.
        let acrossRepositories = Set(rows.flatMap { row -> [ItemID] in
            guard case .bundle(let bundle, true) = row, case .bot = bundle.kind else { return [] }
            return bundle.items.map(\.id)
        })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title):
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                        case .bundle(let bundle, let isExpanded):
                            BundleRow(
                                bundle: bundle,
                                isExpanded: isExpanded,
                                isSelected: model.panel.selectedID == row.id,
                                onToggle: { model.panel.toggleBundle(bundle.kind) },
                                onDone: { model.done(row.id) }
                            )
                            .id(row.id)
                        case .item(let item, let depth):
                            ThreadRow(
                                item: item,
                                isSelected: model.panel.selectedID == row.id,
                                isChecked: model.panel.checked.contains(item.id),
                                showsWaiting: waiting,
                                showsRepository: !model.panel.groupByRepository || acrossRepositories.contains(item.id),
                                lenses: model.lenses(for: item.id),
                                spokenState: model.spokenState(for: item),
                                fallback: model.isPractice ? model.facts(for: item.id) : nil,
                                onOpen: {
                                    model.panel.select(row.id)
                                    if model.open(row.id) { close() }
                                },
                                onToggleCheck: { model.panel.toggleChecked(row.id) },
                                onDone: { model.done(row.id) },
                                onSnooze: { model.beginSnooze(row.id) },
                                onUnsubscribe: { model.unsubscribe(row.id) }
                            )
                            .padding(.leading, depth > 0 ? 14 : 0)
                            .id(row.id)
                        }
                    }
                }
            }
            .onChange(of: model.panel.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    // MARK: Overlays

    @ViewBuilder private var overlay: some View {
        switch model.panel.overlay {
        case .none:
            EmptyView()
        case .snooze:
            SnoozePicker(model: model)
        case .commands:
            CommandMenu(model: model, close: close)
        case .help:
            KeymapOverlay()
                .onTapGesture { model.panel.overlay = .none }
        case .peek:
            if let item = model.panel.selectedItem {
                PeekView(item: item)
                    .onTapGesture { model.panel.overlay = .none }
            }
        case .zero:
            ZeroPicker(model: model)
        case .why:
            if let item = model.panel.selectedItem {
                WhyCard(item: item, actor: model.facts(for: item.id)?.author?.login)
                    .onTapGesture { model.panel.overlay = .none }
            }
        case .tips:
            TipsCard()
                .onTapGesture { model.dismissTips() }
        case .saveSearch:
            SaveSearchPrompt(model: model)
        case .welcome:
            if let welcome = model.welcome {
                ZStack {
                    Color.black.opacity(0.15)
                    WelcomeView(model: model, welcome: welcome)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if model.panel.section == .myPullRequests {
                Hint(key: "⏎", label: "open")
                Hint(key: "n", label: "nudge")
                Hint(key: "h", label: "remind")
                Hint(key: "y", label: "copy link")
                Hint(key: "?", label: "keys")
            } else if model.panel.checked.isEmpty, model.panel.selectedBundle != nil {
                Hint(key: "⏎", label: "open bundle")
                Hint(key: "e", label: "done all")
                Hint(key: "x", label: "select all")
                Hint(key: "?", label: "keys")
            } else if model.panel.checked.isEmpty {
                Hint(key: "e", label: "done")
                Hint(key: "h", label: "snooze")
                Hint(key: "u", label: "unsub")
                Hint(key: "⏎", label: "open")
                Hint(key: "?", label: "keys")
            } else {
                Text("\(model.panel.checked.count) selected").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Hint(key: "e", label: "done all")
                Hint(key: "esc", label: "clear")
            }
            Spacer()
            SettingsMenu(model: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct SectionTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(isPrimary ? Color.white : Color.secondary)
                        .background(isPrimary ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct EmptyState: View {
    let model: AppModel
    let filtered: Bool

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            if !filtered, model.panel.section == .split(.needsMe) {
                // Caught up: the logo's happy cat.
                LogoImage(size: 48)
            } else {
                Image(systemName: filtered ? "magnifyingglass" : "tray")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
            }
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            if !filtered, case .split = model.panel.section, clearedToday > 0 {
                HStack(spacing: 4) {
                    Text("\(clearedToday) cleared by rules today").foregroundStyle(.tertiary)
                    Button("View") { model.panel.show(.cleared) }.buttonStyle(.link)
                }
                .font(.system(size: 11))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var clearedToday: Int {
        (model.inbox?.state.cleared ?? []).filter { $0.rule != nil && Calendar.current.isDateInToday($0.at) }.count
    }

    private var title: String {
        if filtered { return "No matches" }
        switch model.panel.section {
        case .split(.needsMe): return "Nothing needs you"
        case .split: return "All clear"
        case .saved(let id): return "Nothing matches \(model.inbox?.savedSearch(id)?.query ?? "this search")"
        case .myPullRequests: return "No open pull requests"
        case .snoozed: return "Nothing snoozed"
        case .later: return "Nothing saved for later"
        case .cleared: return "Nothing cleared this week"
        }
    }
}

/// What rules and bulk clears took away this week, newest first, each with
/// its page and a way back.
struct ClearedList: View {
    let model: AppModel

    var body: some View {
        if (model.inbox?.state.cleared ?? []).isEmpty {
            EmptyState(model: model, filtered: false)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach((model.inbox?.state.cleared ?? []).reversed()) { entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.reference).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                Text(entry.title).font(.system(size: 12)).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(entry.rule?.title ?? "Bulk").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(Age.short(Date.now.timeIntervalSince(entry.at))).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Button("Restore") { model.restore(entry) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                        .onTapGesture { model.openURL(entry.webURL) }
                        .help("Open \(entry.reference) on GitHub")
                    }
                }
            }
        }
    }
}

struct SnoozePicker: View {
    @Bindable var model: AppModel

    /// The pull request a reminder is being set on, if that is what this is.
    private var pullRequest: String? {
        if case .pullRequest(let id) = model.panel.snoozeTarget { return id }
        return nil
    }

    private var title: String {
        if pullRequest != nil { return "Remind me if nobody answers by" }
        return model.panel.snoozeOnlyIfQuiet ? "Remind me if nothing happens by" : "Snooze until"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            ForEach(SnoozeOption.all) { option in
                Button {
                    model.chooseSnooze(option.date())
                } label: {
                    HStack {
                        Text(option.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(option.title).font(.system(size: 12))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            Divider()
            if let pullRequest {
                if model.followUp(for: pullRequest) != nil {
                    Button {
                        model.panel.overlay = .none
                        model.clearReminder(pullRequest)
                    } label: {
                        HStack {
                            Text("x").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text("Remove the reminder").font(.system(size: 12))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("If nobody has reviewed or commented by then, it shows in Needs me.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle(isOn: Bindable(model.panel).snoozeOnlyIfQuiet) {
                    HStack {
                        Text("n").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text("Only if nothing happens").font(.system(size: 12))
                    }
                }
                .toggleStyle(.checkbox)
                Text(model.panel.snoozeOnlyIfQuiet
                    ? "Comes back on any new activity; at the time, only if there was none."
                    : "Comes back early if something new needs you.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
    }
}

/// Names the current search before it becomes a split.
struct SaveSearchPrompt: View {
    let model: AppModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save search as a split").font(.system(size: 12, weight: .semibold))
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
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
        .onAppear { focused = true }
    }
}

/// "Why is this here?": the classifier's reasoning for the selected thread.
struct WhyCard: View {
    let item: InboxItem
    let actor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why it's in \(item.classification.split.title)").font(.system(size: 12, weight: .semibold))
            Text(item.classification.because).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                fact("GitHub's reason", item.thread.reason.rawValue.replacingOccurrences(of: "_", with: " "))
                fact("Label", item.classification.badge.title)
                if let rule = item.classification.routedBy { fact("Rule", rule.title) }
                if let actor { fact("Opened by", actor + (item.classification.actorKind.map { $0 == .human ? "" : " (\($0.title))" } ?? "")) }
                if let note = item.resurfacing?.note { fact("Back because", String(note.dropFirst("back: ".count))) }
            }
            Text("Wrong? Mute the repository, mark an account as a bot or turn the rule off in Settings.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
        .font(.system(size: 11))
    }
}

/// The three keys worth learning first, shown once.
struct TipsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Three keys to start with").font(.system(size: 13, weight: .semibold))
            tip("e", "Done: it leaves until something new happens.")
            tip("h", "Snooze: it comes back later, or sooner if it needs you.")
            tip("⇥", "Next split: Needs me, Team, Following, Feed.")
            Text("⌘K finds everything else. Press any key to start.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 26, height: 22)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

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

struct CommandMenu: View {
    let model: AppModel
    let close: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var commands: [Command] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Command.all : Command.all.filter { $0.title.localizedStandardContains(trimmed) }
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
        command.run(model)
        if command.closesPanel { close() }
    }
}

struct KeymapOverlay: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keys").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
            ForEach(Command.all.filter { !$0.keys.isEmpty }) { command in
                HStack {
                    Text(command.keys).font(.system(size: 11, design: .monospaced)).frame(width: 60, alignment: .leading)
                    Text(command.title).font(.system(size: 11))
                }
            }
            HStack {
                Text("j k").font(.system(size: 11, design: .monospaced)).frame(width: 60, alignment: .leading)
                Text("Move (space, ⌃F, ⌃B page; gg, G ends)").font(.system(size: 11))
            }
            Text("Any key closes").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 10)
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

struct ToastStack: View {
    let toasts: [Panel.Toast]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            ForEach(toasts) { toast in
                Text(toast.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85), value: toasts)
    }
}

/// One line above the footer: an error, a rate-limit cooldown, a warning
/// or an available update, whichever matters most.
struct StatusStrip: View {
    let message: AppModel.StatusMessage
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10))
            text.font(.system(size: 11)).lineLimit(2)
            Spacer()
            switch message {
            case .error:
                Button(action: model.dismissError) { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain)
                    .help("Dismiss")
            case .update(let release):
                Button("Copy command") {
                    model.updates.copyUpgradeCommand()
                    model.panel.toast("Copied \(Updates.upgradeCommand)")
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("\(Updates.upgradeCommand) installs \(release.version)")
                Button("What's new") { model.openURL(release.url) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            case .cooldown, .warning:
                EmptyView()
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
    }

    @ViewBuilder private var text: some View {
        switch message {
        case .error(let message), .warning(let message):
            Text(message)
        case .cooldown(let until):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(until.timeIntervalSince(context.date)))
                Text("GitHub's rate limit: paused, resuming in \(seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s")")
            }
        case .update(let release):
            Text("Caton \(release.version) is available")
        }
    }

    private var symbol: String {
        switch message {
        case .error: "exclamationmark.triangle.fill"
        case .cooldown: "hourglass"
        case .warning: "exclamationmark.circle"
        case .update: "arrow.down.circle"
        }
    }

    private var color: Color {
        switch message {
        case .error: .orange
        case .cooldown, .warning: .secondary
        case .update: .accentColor
        }
    }
}
