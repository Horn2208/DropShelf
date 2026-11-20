import AppKit
import SwiftUI

/// Transparente Fläche über Stapel/Zeile: Ziehen startet eine Mehrfach-Drag-Session, Klick ruft `onClick`.
struct DragOut: NSViewRepresentable {
    let urls: () -> [URL]
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    var onAirDrop: (() -> Void)?
    var onRestore: (() -> Void)?
    var onDragging: ((Bool) -> Void)?
    var removeTitle = "Entfernen"
    let onMoved: ([URL]) -> Void

    func makeNSView(context: Context) -> DragOutView { DragOutView() }
    func updateNSView(_ v: DragOutView, context: Context) {
        v.urls = urls; v.onClick = onClick; v.onRemove = onRemove; v.onAirDrop = onAirDrop; v.onRestore = onRestore; v.onDragging = onDragging; v.removeTitle = removeTitle; v.onMoved = onMoved
    }
}

final class DragOutView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    var onAirDrop: (() -> Void)?
    var onRestore: (() -> Void)?
    var onDragging: ((Bool) -> Void)?
    var removeTitle = "Entfernen"
    var onMoved: ([URL]) -> Void = { _ in }
    private var downPoint: NSPoint?
    private var dragURLs: [URL] = []
    private var accessed: [URL] = []
    private var keepCopy = false

    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow }

    override func mouseUp(with event: NSEvent) {
        if downPoint != nil { onClick?() }
        downPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        downPoint = nil
        dragURLs = urls()
        guard !dragURLs.isEmpty else { return }
        keepCopy = NSEvent.modifierFlags.contains(.option)
        accessed = dragURLs.filter { $0.startAccessingSecurityScopedResource() }
        let p = convert(start, from: nil)
        let items = dragURLs.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            let o = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(NSRect(x: p.x - 32 + o, y: p.y - 32 - o, width: 64, height: 64), contents: icon)
            return item
        }
        onDragging?(true)
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onRemove != nil else { return nil }
        let m = NSMenu()
        if onRestore != nil { m.addItem(withTitle: "Wiederherstellen", action: #selector(restore), keyEquivalent: "").target = self }
        if onAirDrop != nil {
            m.addItem(withTitle: "Per AirDrop senden", action: #selector(airDrop), keyEquivalent: "").target = self
        }
        m.addItem(withTitle: "Im Finder zeigen", action: #selector(reveal), keyEquivalent: "").target = self
        m.addItem(withTitle: removeTitle, action: #selector(remove), keyEquivalent: "").target = self
        return m
    }

    @objc private func restore() { onRestore?() }
    @objc private func airDrop() { onAirDrop?() }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting(urls()) }
    @objc private func remove() { onRemove?() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Innerhalb der App nur Kopieren: Aktionsknöpfe (Senden) und andere Ablagen.
        context == .outsideApplication ? [.copy, .move, .generic] : [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        accessed = []
        onDragging?(false)
        // Mit Wahltaste oder beim Ablegen auf eigene Fenster (Aktionsknöpfe, Ablagen) bleiben die Einträge in der Ablage.
        let own = MainActor.assumeIsolated {
            NSApp.windows.contains { ($0 is ActionsPanel || $0 is ShelfPanel) && $0.isVisible && $0.frame.contains(screenPoint) }
        }
        if operation != [] && !keepCopy && !own { onMoved(dragURLs) }
        dragURLs = []
    }
}
