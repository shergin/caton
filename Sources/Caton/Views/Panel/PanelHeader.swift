import CatonCore
import SwiftUI

/// The logo, the mode, the window and command buttons, and the tabs.
struct PanelHeader: View {
    let model: AppModel

    var body: some View {
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
