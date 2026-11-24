import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    enum Mode { case listening, lockedListening, transcribing }
    @Published var mode: Mode = .listening
    @Published var level: Float = 0
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    private let shape: [CGFloat] = [0.35, 0.55, 0.8, 1, 0.8, 0.55, 0.35]
    private let vermilion = Color(.sRGB, red: 0.84, green: 0.24, blue: 0.17)

    var body: some View {
        HStack(spacing: 4) {
            if model.mode == .transcribing {
                ProgressView().controlSize(.small).environment(\.colorScheme, .dark)
            } else {
                if model.mode == .lockedListening {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(vermilion)
                        .padding(.trailing, 2)
                }
                ForEach(shape.indices, id: \.self) { i in
                    Capsule()
                        .fill(model.mode == .lockedListening ? vermilion : Color.white)
                        .frame(width: 3, height: 4 + CGFloat(model.level) * 16 * shape[i])
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: model.level)
        .frame(width: model.mode == .lockedListening ? 92 : 76, height: 28)
        .background(
            Capsule()
                .fill(.black.opacity(0.86))
                .overlay(
                    Capsule()
                        .strokeBorder(model.mode == .lockedListening ? vermilion.opacity(0.6) : .white.opacity(0.12), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small pill at the bottom of the screen showing that Koe is listening, locked hands-free, or thinking.
final class HUD {
    let model = HUDModel()
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 112, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ mode: HUDModel.Mode) {
        model.mode = mode
        if mode == .listening { model.level = 0 }
        guard !panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 20))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
