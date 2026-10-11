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
        VStack(alignment: .leading, spacing: 2) {
            CardTitle(title).padding(.bottom, 6)
            ForEach(SnoozeOption.all) { option in
                MenuRow(key: option.key, title: option.title) { model.chooseSnooze(option.date()) }
            }
            Divider().padding(.vertical, 6)
            if let pullRequest {
                if model.followUp(for: pullRequest) != nil {
                    MenuRow(key: "x", title: "Remove the reminder") {
                        model.panel.overlay = .none
                        model.clearReminder(pullRequest)
                    }
                }
                CardNote("If nobody has reviewed or commented by then, it shows in Needs me.")
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            } else {
                MenuRow(key: "n", title: "Only if nothing happens") {
                    model.panel.snoozeOnlyIfQuiet.toggle()
                } trailing: {
                    Image(systemName: model.panel.snoozeOnlyIfQuiet ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(model.panel.snoozeOnlyIfQuiet ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
                CardNote(model.panel.snoozeOnlyIfQuiet
                    ? "Comes back on any new activity; at the time, only if there was none."
                    : "Comes back early if something new needs you.")
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            }
        }
        .card(width: 260, padding: 10)
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
