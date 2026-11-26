import AppKit
import Combine
import Quartz
import SwiftUI

/// Verschiebt das Fenster per `performDrag` (SwiftUI-Inhalt schluckt sonst die Ereignisse).
/// `onPress`: läuft bei jedem Mausdruck auf dieser Fläche (z. B. Auswahl aufheben), ohne das Panel zum Schlüssel zu machen.
struct WindowDragArea: NSViewRepresentable {
    var onPress: (() -> Void)?
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ v: WindowDragView, context: Context) { v.onPress = onPress }
}

/// Griff oben: nur hier reagiert die Maus (Hover-Hervorhebung, Cursor, Ziehen). Der Rest der Ablage bleibt still.
struct DragPill: View {
    @State private var hover = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(hover ? 0.45 : 0.25))
            .frame(width: 36, height: 5)
            .frame(width: 56, height: 16)
            .contentShape(Rectangle())
            .background(WindowDragArea())
            .onHover { hover = $0 }
            .animation(Motion.snappy, value: hover)
    }
}

final class WindowDragView: NSView {
    var onPress: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        onPress?()
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
    private var selectSub: AnyCancellable?
    private var resizing = false  // Auf-/Zuklapp-Animation läuft: Schatten/Glas erst am Ende nachziehen
    private var resizeGen = 0     // Umkehr mitten in der Animation: nur der letzte Abschluss zählt

    init(shelf: Shelf, origin: CGPoint) {
        self.shelf = shelf
        actions = ActionsPanel(shelf: shelf)
        super.init(contentRect: NSRect(origin: origin, size: CGSize(width: Self.width, height: Self.collapsedHeight)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        // Klick/Ziehen macht das Panel nicht zum Schlüsselfenster: Jeder Schlüssel-Wechsel baut auf macOS 26 Glas und
        // Schatten um (anderes Aussehen). Schlüssel wird es nur noch per `makeKey()` (Quick Look) oder für Textfelder.
        becomesKeyOnlyIfNeeded = true
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

        // Auswahl ändert sich bei offener Vorschau → Quick Look zeigt die neue Auswahl (Sink läuft vor der Änderung).
        selectSub = shelf.$selection.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reloadQuickLook() }
        }

        expandSub = shelf.$expanded.dropFirst().sink { [weak self] open in
            guard let self else { return }
            if !open { self.shelf.selection.clear() }
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
                    // Aufklappen: Ease-out (0,16, 1, 0,3, 1) 0,34 s ohne Überschwingen; Zuklappen 0,14 s mit Ease-in.
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

    /// Panel zur Ablage zum Schlüsselfenster machen (Auswahl, Umbenennen) – nicht beim Verschieben über freies Glas.
    static func focus(_ shelf: Shelf) {
        NSApp.windows.first { ($0 as? ShelfPanel)?.shelf === shelf }?.makeKey()
    }

    /// Quick Look zeigt die markierten Dateien, ohne Auswahl alle.
    private var previewURLs: [URL] {
        let sel = shelf.items.filter { shelf.selection.ids.contains($0.id) }
        return (sel.isEmpty ? shelf.items : sel).map(\.url)
    }

    func toggleQuickLook() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && ql.isVisible { ql.orderOut(nil); return }
        guard !shelf.items.isEmpty else { return }
        makeKey()
        ql.makeKeyAndOrderFront(nil)
    }

    private func reloadQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible, ql.dataSource === self else { return }
        ql.reloadData()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: toggleQuickLook()                                   // Leertaste
        case 53: shelf.selection.clear()                             // Esc
        case 123, 126: if shelf.expanded { shelf.selection.step(-1) } // ← ↑
        case 124, 125: if shelf.expanded { shelf.selection.step(1) }  // → ↓
        default: super.keyDown(with: event)
        }
    }

    // Vermutung: Beim Schlüssel-Wechsel legt macOS 26 neue Glas-Ebenen an; wie beim Verschieben die eigenen Werte nachziehen.
    func windowDidBecomeKey(_ notification: Notification) { GlassKit.retintSoon(contentView) }
    func windowDidResignKey(_ notification: Notification) { GlassKit.retintSoon(contentView) }

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

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = previewURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
