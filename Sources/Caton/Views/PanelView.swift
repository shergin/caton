import CatonCore
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    let close: () -> Void

    var body: some View {
        Group {
            switch model.account {
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
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isSearching || !model.searchQuery.isEmpty { searchField }
            Divider().opacity(0.5)
            ZStack(alignment: .bottom) {
                content
                ToastStack(toasts: model.toasts)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            .overlay { overlay }
            Divider().opacity(0.5)
            if let error = model.errorMessage { ErrorStrip(message: error, dismiss: model.dismissError) }
            footer
        }
        .onChange(of: model.isSearching) { _, searching in searchFocused = searching }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LogoImage(size: 16)
                Text("Caton").font(.system(size: 13, weight: .semibold))
                if model.dryRun {
                    Text("DRY RUN").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                }
                if model.isSyncing { ProgressView().controlSize(.mini) }
                Spacer()
                Button { model.overlay = .commands } label: {
                    Text("⌘K").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Commands")
            }
            HStack(spacing: 4) {
                ForEach(Split.allCases, id: \.self) { split in
                    SectionTab(title: split.title, count: model.snapshot.count(split), isSelected: model.section == .split(split), isPrimary: split == .needsMe) {
                        model.show(.split(split))
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Snoozed (\(model.count(.snoozed)))") { model.show(.snoozed) }
                    Button("Later (\(model.count(.later)))") { model.show(.later) }
                    Button("Cleared (\(model.count(.cleared)))") { model.show(.cleared) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Snoozed, Later and Cleared")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Filter by title or repository", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { model.isSearching = false }
                .onKeyPress(.tab) {
                    model.isSearching = false
                    return .handled
                }
                .onExitCommand {
                    model.searchQuery = ""
                    model.isSearching = false
                }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: List

    @ViewBuilder private var content: some View {
        switch model.section {
        case .cleared:
            ClearedList(model: model)
        default:
            let items = model.visibleItems
            if items.isEmpty {
                EmptyState(section: model.section, filtered: !model.searchQuery.isEmpty || model.unreadOnly, clearedToday: model.cleared.count)
            } else {
                list(items)
            }
        }
    }

    private func list(_ items: [InboxItem]) -> some View {
        let groups = groups(items)
        let waiting = model.section == .split(.needsMe)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.items) { item in
                                ThreadRow(
                                    item: item,
                                    isSelected: model.selectedID == item.id,
                                    isChecked: model.checked.contains(item.id),
                                    showsWaiting: waiting,
                                    showsRepository: !model.groupByRepository,
                                    lenses: model.lenses(for: item.id),
                                    onOpen: {
                                        model.select(item.id)
                                        if model.open(item.id) { close() }
                                    },
                                    onToggleCheck: { model.toggleChecked(item.id) },
                                    onDone: { model.done(item.id) },
                                    onSnooze: {
                                        model.select(item.id)
                                        model.overlay = .snooze
                                    },
                                    onUnsubscribe: { model.unsubscribe(item.id) }
                                )
                                .id(item.id)
                            }
                        } header: {
                            if let title = group.header {
                                Text(title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                            }
                        }
                    }
                }
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private struct Group {
        let title: String
        let header: String?
        let items: [InboxItem]
    }

    private func groups(_ items: [InboxItem]) -> [Group] {
        guard model.groupByRepository else { return [Group(title: "all", header: nil, items: items)] }
        var groups: [Group] = []
        for item in items {
            let name = item.thread.repository.fullName
            if let last = groups.last, last.title == name {
                groups[groups.count - 1] = Group(title: name, header: name, items: last.items + [item])
            } else {
                groups.append(Group(title: name, header: name, items: [item]))
            }
        }
        return groups
    }

    // MARK: Overlays

    @ViewBuilder private var overlay: some View {
        switch model.overlay {
        case .none:
            EmptyView()
        case .snooze:
            SnoozePicker(model: model)
        case .commands:
            CommandMenu(model: model, close: close)
        case .help:
            KeymapOverlay()
                .onTapGesture { model.overlay = .none }
        case .peek:
            if let item = model.selectedItem {
                PeekView(item: item)
                    .onTapGesture { model.overlay = .none }
            }
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
            if model.checked.isEmpty {
                Hint(key: "e", label: "done")
                Hint(key: "h", label: "snooze")
                Hint(key: "u", label: "unsub")
                Hint(key: "⏎", label: "open")
                Hint(key: "?", label: "keys")
            } else {
                Text("\(model.checked.count) selected").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Hint(key: "e", label: "done all")
                Hint(key: "esc", label: "clear")
            }
            Spacer()
            SettingsMenu(model: model)
                // Clear of the resize grip in the corner.
                .padding(.trailing, 10)
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
    let section: AppModel.Section
    let filtered: Bool
    let clearedToday: Int

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            if !filtered, section == .split(.needsMe) {
                // Caught up: the logo's happy cat.
                LogoImage(size: 48)
            } else {
                Image(systemName: filtered ? "magnifyingglass" : "tray")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
            }
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            if section == .split(.needsMe), !filtered, clearedToday > 0 {
                Text("\(clearedToday) cleared by rules this week").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        if filtered { return "No matches" }
        switch section {
        case .split(.needsMe): return "Nothing needs you"
        case .split: return "All clear"
        case .snoozed: return "Nothing snoozed"
        case .later: return "Nothing saved for later"
        case .cleared: return "Nothing cleared"
        }
    }
}

struct ClearedList: View {
    let model: AppModel

    var body: some View {
        if model.cleared.isEmpty {
            EmptyState(section: .cleared, filtered: false, clearedToday: 0)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.cleared.reversed()) { entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.reference).font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(entry.title).font(.system(size: 12)).lineLimit(1)
                            }
                            Spacer()
                            Text(entry.rule?.title ?? "Bulk").font(.system(size: 10)).foregroundStyle(.secondary)
                            Button("Restore") { model.restore(entry) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                    }
                }
            }
        }
    }
}

struct SnoozePicker: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snooze until").font(.system(size: 12, weight: .semibold))
            ForEach(SnoozeOption.all) { option in
                Button {
                    model.overlay = .none
                    model.snooze(until: option.date())
                } label: {
                    HStack {
                        Text(option.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(option.title).font(.system(size: 12))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            Text("Comes back early if something new needs you.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 240)
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
        model.overlay = .none
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

    var body: some View {
        Menu {
            Section("Rules") {
                ForEach(Rule.allCases, id: \.self) { rule in
                    Toggle(rule.title, isOn: Binding(get: { model.isEnabled(rule) }, set: { model.setEnabled(rule, $0) }))
                }
                Toggle("Mark rule-cleared threads done on GitHub", isOn: Binding(get: { model.preferences.syncRuleClears }, set: { model.preferences.syncRuleClears = $0 }))
            }
            if !model.mutedRepositories.isEmpty {
                Menu("Muted repositories") {
                    ForEach(model.mutedRepositories, id: \.self) { repository in
                        Button("Unmute \(repository)") { model.unmute(repository) }
                    }
                }
            }
            Section("View") {
                Toggle("Group by repository", isOn: $model.groupByRepository)
                Toggle("Unread only", isOn: $model.unreadOnly)
            }
            Divider()
            Button("Settings…") { model.openSettings?() }
            Button("Refresh") { model.refresh() }
            if case .signedIn(let viewer) = model.account {
                Button("Sign out @\(viewer.login)") { model.signOut() }
            }
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
    let toasts: [AppModel.Toast]

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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: toasts)
    }
}

struct ErrorStrip: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            Text(message).font(.system(size: 11)).lineLimit(2)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}
