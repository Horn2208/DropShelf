import AppKit
import SwiftUI

/// Transparente Fläche über Stapel/Zeile: Ziehen startet eine Mehrfach-Drag-Session, Klick ruft `onClick`.
struct DragOut: NSViewRepresentable {
    let urls: () -> [URL]
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    let onMoved: ([URL]) -> Void

    func makeNSView(context: Context) -> DragOutView { DragOutView() }
    func updateNSView(_ v: DragOutView, context: Context) {
        v.urls = urls; v.onClick = onClick; v.onRemove = onRemove; v.onMoved = onMoved
    }
}

final class DragOutView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
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
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onRemove != nil else { return nil }
        let m = NSMenu()
        m.addItem(withTitle: "Entfernen", action: #selector(remove), keyEquivalent: "").target = self
        return m
    }

    @objc private func remove() { onRemove?() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        accessed = []
        // Mit Wahltaste bleiben die Einträge in der Ablage.
        if operation != [] && !keepCopy { onMoved(dragURLs) }
        dragURLs = []
    }
}
