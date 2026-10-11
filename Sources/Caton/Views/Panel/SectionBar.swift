import CatonCore
import SwiftUI

/// The top of the panel. On a split: the four splits as a segmented
/// control. On any other view (a saved search, My PRs, Snoozed, Later,
/// Cleared): its title, with the way back to the split shown before, the
/// way Control Center drills into a module. The More menu on the right
/// reaches the views that are not splits.
struct SectionBar: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOnSplit: Bool {
        if case .split = model.panel.section { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            if isOnSplit {
                SplitControl(model: model)
            } else {
                drilledIn
            }
            Spacer(minLength: 0)
            if model.inbox?.isSyncing == true {
                ProgressView().controlSize(.mini)
            }
            MoreMenu(model: model)
        }
        .padding(.horizontal, Theme.Spacing.margin)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOnSplit)
    }

    /// The title of a view outside the splits, and the button back.
    private var drilledIn: some View {
        HStack(spacing: 10) {
            Button { model.panel.showLastSplit() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 26)
                    .background(Theme.Fill.control, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Back to \(model.panel.lastSplit.title)")
            HStack(spacing: 6) {
                Text(model.title(of: model.panel.section)).font(Theme.Font.titleEmphasized)
                let count = model.panel.count(model.panel.section)
                if count > 0 {
                    Text("\(count)").font(Theme.Font.count).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .transition(.opacity)
    }
}

/// The four splits as a segmented control: the selected one is raised on a
/// pill that slides between them.
private struct SplitControl: View {
    let model: AppModel
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Split.allCases, id: \.self) { split in
                Segment(
                    title: split.title,
                    count: model.panel.count(.split(split)),
                    isSelected: model.panel.section == .split(split),
                    countMatters: split == .needsMe,
                    selection: selection
                ) { model.panel.show(.split(split)) }
                .help("\(split.title) · \(split.rawValue + 1)")
            }
        }
        .padding(2)
        .background(Theme.Fill.control, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85), value: model.panel.section)
        .transition(.opacity)
    }
}

/// One segment: the title and, when there is one, the count.
private struct Segment: View {
    let title: String
    let count: Int
    let isSelected: Bool
    /// Needs me: the count is the number that matters, so it is colored.
    let countMatters: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(isSelected ? Theme.Font.segmentSelected : Theme.Font.segment)
                if count > 0 {
                    Text("\(count)").font(Theme.Font.count).foregroundStyle(countStyle)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.12), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(count > 0 ? "\(count)" : "")
    }

    private var countStyle: AnyShapeStyle {
        if countMatters { return AnyShapeStyle(Color.accentColor) }
        return isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
    }
}

/// The views that are not splits, and the saved searches, with counts.
private struct MoreMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(Panel.Section.more, id: \.self) { section in
                Button { model.panel.show(section) } label: {
                    Label(titled(section), systemImage: section.symbol)
                }
            }
            if let saved = model.inbox?.savedSearches, !saved.isEmpty {
                Section("Saved searches") {
                    ForEach(saved) { search in
                        Button { model.panel.show(.saved(search.id)) } label: {
                            Label(titled(.saved(search.id)), systemImage: Panel.Section.saved(search.id).symbol)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("My pull requests, Snoozed, Later, Cleared and saved searches")
    }

    private func titled(_ section: Panel.Section) -> String {
        let count = model.panel.count(section)
        return count > 0 ? "\(model.title(of: section)) (\(count))" : model.title(of: section)
    }
}
