import CatonCore
import SwiftUI

/// What the panel or the window shows: the inbox, or sign-in.
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

/// The signed-in panel, top to bottom: the mode strip when the inbox is not
/// the account's, the section bar, the search, the list with its toasts and
/// the overlay on top, the status strip, and the footer.
struct InboxView: View {
    @Bindable var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ModeStrip(model: model)
            SectionBar(model: model)
            if model.panel.isSearching || !model.panel.searchQuery.isEmpty { SearchField(model: model) }
            Divider().opacity(0.5)
            ZStack(alignment: .bottom) {
                InboxList(model: model, close: close)
                ToastStack(toasts: model.panel.toasts)
                    .padding(.horizontal, Theme.Spacing.margin)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            .overlay { overlay }
            Divider().opacity(0.5)
            if let status = model.statusMessage { StatusStrip(message: status, model: model) }
            PanelFooter(model: model, close: close)
        }
    }

    // MARK: Overlays

    /// The overlay on top of the list. Each takes its keys in its own
    /// `handle(_:model:)`, beside its view, which `KeyRouter` calls.
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
}
