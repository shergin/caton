import AppKit
import CatonCore
import SwiftUI

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
