import AppKit
import Combine
import SwiftUI

/// Verschiebt das Fenster per `performDrag` (SwiftUI-Inhalt schluckt sonst die Ereignisse).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ v: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        window?.performDrag(with: event)
        (window as? ShelfPanel)?.clampToScreen()
        window?.invalidateCursorRects(for: self)
    }
}

@MainActor
final class ShelfPanel: NSPanel, NSWindowDelegate {
    static let width: CGFloat = 220
    static let collapsedHeight: CGFloat = 250
    static let expandedHeight: CGFloat = 390

    let shelf: Shelf
    private let actions: ActionsPanel
    private var expandSub: AnyCancellable?

    init(shelf: Shelf, origin: CGPoint) {
        self.shelf = shelf
        actions = ActionsPanel(shelf: shelf)
        super.init(contentRect: NSRect(origin: origin, size: CGSize(width: Self.width, height: Self.collapsedHeight)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true  // Rückfall; zuverlässig macht es WindowDragArea
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        delegate = self

        // Echtes Glas: Effekt-View hinter dem Fenster, rund maskiert; Schatten folgt der runden Form.
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = ShelfView.radius
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        let host = NSHostingView(rootView: ShelfView(shelf: shelf) { ShelfManager.shared.close(shelf.id) })
        host.frame = fx.bounds
        host.autoresizingMask = [.width, .height]
        fx.addSubview(host)
        contentView = fx

        actions.anchorWindow = self
        clampToScreen()
        actions.setFrame(actionsFrame(for: frame), display: false)
        actions.orderFront(nil)
        DispatchQueue.main.async { self.invalidateShadow() }

        expandSub = shelf.$expanded.dropFirst().sink { [weak self] open in
            guard let self else { return }
            var f = self.frame
            let h = open ? Self.expandedHeight : Self.collapsedHeight
            f.origin.y += f.height - h  // obere Kante bleibt
            f.size.height = h
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.setFrame(f, display: true)
                self.actions.setFrame(self.actionsFrame(for: f), display: true)
            } else {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = ShelfView.animationDuration
                    c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.animator().setFrame(f, display: true)
                    self.actions.animator().setFrame(self.actionsFrame(for: f), display: true)
                }
            }
        }
    }

    /// Aktionsleiste: schmaler Streifen direkt unter der Ablage.
    private func actionsFrame(for f: NSRect) -> NSRect {
        NSRect(x: f.midX - ActionsPanel.size.width / 2, y: f.minY - ActionsPanel.size.height - 2,
               width: ActionsPanel.size.width, height: ActionsPanel.size.height)
    }

    /// Hält Ablage (und Leiste darunter) im sichtbaren Bildschirmbereich.
    func clampToScreen() {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var o = frame.origin
        o.x = min(max(o.x, vf.minX), vf.maxX - frame.width)
        o.y = min(max(o.y, vf.minY + ActionsPanel.size.height + 2), vf.maxY - frame.height)
        if o != frame.origin { setFrameOrigin(o) }
    }

    override func close() {
        actions.close()
        super.close()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { ShelfManager.shared.lastActive = shelf.id }
        super.sendEvent(event)
    }

    func windowDidMove(_ notification: Notification) {
        actions.setFrame(actionsFrame(for: frame), display: true)
        ShelfManager.shared.save()
    }

    func windowDidResize(_ notification: Notification) { invalidateShadow() }
}
