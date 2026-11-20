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
    private var resizing = false  // Auf-/Zuklapp-Animation läuft: Schatten/Glas erst am Ende nachziehen
    private var resizeGen = 0     // Umkehr mitten in der Animation: nur der letzte Abschluss zählt

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
        // Neu anwenden bei Regler-Änderung und wenn SwiftUI neue Glas-Ebenen anlegt (Kapsel/Knöpfe bei Dateien, Detail-Ansicht).
        tintSub = Publishers.MergeMany(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.eraseToAnyPublisher(),
            shelf.$items.map { _ in () }.eraseToAnyPublisher(), shelf.$expanded.map { _ in () }.eraseToAnyPublisher())
            .sink { [weak self] _ in GlassKit.retintSoon(self?.contentView) }

        actions.anchorWindow = self
        clampToScreen()
        actions.setFrame(actionsFrame(for: frame), display: false)
        addChildWindow(actions, ordered: .above)  // Kindfenster: bewegt sich beim Ziehen ohne Nachlauf mit
        DispatchQueue.main.async { self.invalidateShadow() }

        expandSub = shelf.$expanded.dropFirst().sink { [weak self] open in
            guard let self else { return }
            let size = open ? Self.detailSize : CGSize(width: Self.width, height: Self.collapsedHeight)
            // Oberkante und waagrechte Mitte bleiben: wächst nur nach unten und gleichmäßig zu beiden Seiten.
            let old = self.frame
            let f = self.clamped(NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height))
            if Motion.enabled {
                // Während der Animation lösen, sonst verschiebt AppKit das Kindfenster zusätzlich zur eigenen Animation.
                // Unterbrechbar: Der neue Rahmen geht vom aktuellen (Zwischen-)Rahmen aus, die Animation zielt einfach neu.
                self.removeChildWindow(self.actions)
                self.resizing = true
                self.resizeGen += 1
                let gen = self.resizeGen
                NSAnimationContext.runAnimationGroup({ c in
                    // Aufklappen: Ease-out 0,24 s; Zuklappen halb so lang mit Ease-in (Schließen geht schneller).
                    c.duration = open ? Motion.Curve.expand : Motion.Curve.collapse
                    c.timingFunction = open ? Motion.Curve.enter : Motion.Curve.exit
                    self.animator().setFrame(f, display: true)
                    self.actions.animator().setFrame(self.actionsFrame(for: f), display: true)
                }, completionHandler: { MainActor.assumeIsolated {
                    guard gen == self.resizeGen else { return }
                    self.resizing = false
                    self.windowDidResize(Notification(name: NSWindow.didResizeNotification))
                    self.actions.setFrame(self.actionsFrame(for: self.frame), display: true)
                    if self.isVisible { self.addChildWindow(self.actions, ordered: .above) }
                } })
            } else {
                self.setFrame(f, display: true)
                self.actions.setFrame(self.actionsFrame(for: f), display: true)
            }
        }
    }

    /// Pop beim Öffnen: Fenster fix, Inhalt federt auf, Panel blendet ein.
    func popIn() {
        FunEffects.onPop(screen: screen)
        guard Motion.userOn else { shelf.appeared = true; DispatchQueue.main.async { GlassKit.retint(self.contentView) }; return }
        alphaValue = 0
        DispatchQueue.main.async {
            withAnimation(Motion.pop) { self.shelf.appeared = true }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; $0.timingFunction = Motion.Curve.enter; self.animator().alphaValue = 1 }
            GlassKit.retint(self.contentView)  // Glas-Ebenen gibt es erst auf dem Bildschirm
        }
    }

    /// Kurz schrumpfen + ausblenden, dann `done`.
    func animateOut(_ done: @escaping @MainActor () -> Void) {
        guard Motion.userOn else { done(); return }
        withAnimation(Motion.close) { shelf.closing = true }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Motion.Curve.collapse
            c.timingFunction = Motion.Curve.exit
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
        ShelfManager.shared.save()  // Aktionsleiste folgt als Kindfenster
        // Beim Verschieben (`performDrag`, Schlüsselfenster per Klick) baut das System sein Glas um; neue Filter fängt
        // `BackdropPatch` ab, falls dabei eine neue Glas-Ebene entsteht, bekommt sie hier ihre Werte (sonst nur Lesen).
        GlassKit.retintSoon(contentView)
    }


    func windowDidResize(_ notification: Notification) {
        guard !resizing else { return }
        invalidateShadow()
        GlassKit.retint(contentView)
    }

    /// Form für den Fensterschatten. Ohne sie zeichnet macOS 26+ beim Schlüsselfenster (Klick, Quick Look) einen
    /// eckigen Schatten samt Kante um das ganze Fenster – der „Kasten“ hinter der runden Ablage.
    /// Private AppKit-Methode (wie bei NSVisualEffectView.maskImage); wird nur aufgerufen, nie vorausgesetzt.
    @objc func _cornerMask() -> NSImage? { Self.cornerMask }

    private static let cornerMask: NSImage = {
        let r = ShelfView.radius, d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }()

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { shelf.items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { shelf.items[index].url as NSURL }
}
