import AppKit
import Combine
import SwiftUI

@MainActor
final class ShelfPanel: NSPanel, NSWindowDelegate {
    let shelf: Shelf
    private var expandSub: AnyCancellable?

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
        expandSub = shelf.$expanded.dropFirst().sink { [weak self] open in
            guard let self else { return }
            let h: CGFloat = open ? 360 : 220
            var f = self.frame
            f.origin.y += f.height - h  // obere Kante bleibt
            f.size.height = h
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.setFrame(f, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = ShelfView.animationDuration
                    c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.animator().setFrame(f, display: true)
                }
            }
        }
        contentView = NSHostingView(rootView: ShelfView(shelf: shelf) { ShelfManager.shared.close(shelf.id) })
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { ShelfManager.shared.lastActive = shelf.id }
        super.sendEvent(event)
    }

    func windowDidMove(_ notification: Notification) { ShelfManager.shared.save() }
}
