import AppKit
import SwiftUI

/// A semi-transparent, optionally always-on-top panel for displaying live subtitles.
@MainActor
final class FloatingSubtitlePanel {

    private var panel: NSPanel?
    private let streamer: WebSocketStreamer

    var isVisible: Bool { panel?.isVisible ?? false }

    init(streamer: WebSocketStreamer) {
        self.streamer = streamer
    }

    func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }

        let contentView = FloatingSubtitleView(streamer: streamer, panel: self)
        let hostingView = NSHostingView(rootView: contentView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Center near bottom of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 250
            let y = screenFrame.minY + 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        panel?.level = enabled ? .floating : .normal
    }
}
