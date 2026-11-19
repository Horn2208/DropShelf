import AppKit
import Combine
import Quartz
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
final class ShelfPanel: NSPanel, NSWindowDelegate, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let width: CGFloat = 198  // wie Dropovers kleine Ablage (Bildschirmaufnahme: ≈198×206 pt)
    static let collapsedHeight: CGFloat = 206
    static let detailSize = CGSize(width: 420, height: 360)

    let shelf: Shelf
    private let actions: ActionsPanel
    private var expandSub: AnyCancellable?
    private var tintSub: AnyCancellable?

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

        // Ab macOS 26 echtes Liquid Glass (NSGlassEffectView), sonst Effekt-View; Schatten folgt der runden Form.
        let host = NSHostingView(rootView: ShelfView(shelf: shelf) { ShelfManager.shared.close(shelf.id) })
        contentView = GlassKit.wrap(host, radius: ShelfView.radius)
        GlassKit.retint(contentView)
        tintSub = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in GlassKit.retint(self?.contentView) }

        actions.anchorWindow = self
        clampToScreen()
        actions.setFrame(actionsFrame(for: frame), display: false)
        actions.orderFront(nil)
        DispatchQueue.main.async { self.invalidateShadow() }

        expandSub = shelf.$expanded.dropFirst().sink { [weak self] open in
            guard let self else { return }
            let size = open ? Self.detailSize : CGSize(width: Self.width, height: Self.collapsedHeight)
            let c = CGPoint(x: self.frame.midX, y: self.frame.midY)  // Mittelpunkt bleibt, wächst in alle Richtungen
            let f = self.clamped(NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
            if Motion.enabled {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.22  // Dropover: ≈0,2 s, Mitte bleibt
                    c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
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
        FunEffects.onPop(screen: screen)
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

    // Quick Look (Leertaste): Panel darf Taste werden, ohne die App zu aktivieren.
    override var canBecomeKey: Bool { true }

    func toggleQuickLook() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && ql.isVisible { ql.orderOut(nil); return }
        guard !shelf.items.isEmpty else { return }
        makeKey()
        ql.makeKeyAndOrderFront(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { toggleQuickLook() } else { super.keyDown(with: event) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self { panel.dataSource = nil; panel.delegate = nil }
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

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { shelf.items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { shelf.items[index].url as NSURL }
}
