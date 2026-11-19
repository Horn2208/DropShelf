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
    static let detailSize = CGSize(width: 420, height: 360)

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
        fx.material = .underWindowBackground  // transparenter als .hudWindow
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
            let size = open ? Self.detailSize : CGSize(width: Self.width, height: Self.collapsedHeight)
            var f = self.frame
            f.origin.y += f.height - size.height  // obere Kante bleibt
            f.size = size
            f = self.clamped(f)
            if Motion.userOn {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.28
                    c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.animator().setFrame(f, display: true)
                    self.actions.animator().setFrame(self.actionsFrame(for: f), display: true)
                }
            } else {
                self.setFrame(f, display: true)
                self.actions.setFrame(self.actionsFrame(for: f), display: true)
            }
        }
    }

    /// Pop beim Öffnen: Fenster fix, Inhalt federt auf, Panel blendet ein.
    func popIn() {
        guard Motion.userOn else { shelf.appeared = true; return }
        alphaValue = 0
        DispatchQueue.main.async {
            withAnimation(Motion.pop) { self.shelf.appeared = true }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; self.animator().alphaValue = 1 }
        }
    }

    /// Kurz schrumpfen + ausblenden, dann `done`.
    func animateOut(_ done: @escaping @MainActor () -> Void) {
        guard Motion.userOn else { done(); return }
        withAnimation(Motion.pop) { shelf.closing = true }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.15
            self.animator().alphaValue = 0
            self.actions.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { done() } })
    }

    /// Aktionsleiste: schmaler Streifen direkt unter der Ablage.
    private func actionsFrame(for f: NSRect) -> NSRect {
        NSRect(x: f.midX - ActionsPanel.size.width / 2, y: f.minY - ActionsPanel.size.height - 2,
               width: ActionsPanel.size.width, height: ActionsPanel.size.height)
    }

    /// Rahmen im sichtbaren Bildschirmbereich (Aktionsleiste darunter mitgerechnet).
    private func clamped(_ f: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var o = f.origin
        o.x = min(max(o.x, vf.minX), vf.maxX - f.width)
        o.y = min(max(o.y, vf.minY + ActionsPanel.size.height + 2), vf.maxY - f.height)
        return NSRect(origin: o, size: f.size)
    }

    func clampToScreen() {
        let o = clamped(frame).origin
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
