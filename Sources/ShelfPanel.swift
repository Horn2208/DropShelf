import AppKit
import SwiftUI

@MainActor
final class ShelfPanel: NSPanel, NSWindowDelegate {
    let shelf: Shelf

    init(shelf: Shelf, origin: CGPoint) {
        self.shelf = shelf
        super.init(contentRect: NSRect(origin: origin, size: CGSize(width: 200, height: 220)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        delegate = self
        contentView = NSHostingView(rootView: ShelfView(shelf: shelf) { ShelfManager.shared.close(shelf.id) })
    }

    func windowDidMove(_ notification: Notification) { ShelfManager.shared.save() }
}
