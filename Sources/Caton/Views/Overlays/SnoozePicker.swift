import CatonCore
import SwiftUI

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

extension SnoozePicker {
    /// A digit picks the time. On threads `n` switches to "only if nothing
    /// happens"; on a reminder `x` removes it.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        let panel = model.panel
        if key.special == .escape {
            panel.overlay = .none
            return .handled
        }
        guard !key.isRepeat, key.shortcutModifiers.isEmpty else { return .handled }
        switch (panel.snoozeTarget, key.characters) {
        case (.pullRequest(let id), "x"):
            panel.overlay = .none
            model.clearReminder(id)
        case (.threads, "n"):
            panel.snoozeOnlyIfQuiet.toggle()
        default:
            if let option = SnoozeOption.all.first(where: { $0.key == key.characters }) { model.chooseSnooze(option.date()) }
        }
        return .handled
    }
}
