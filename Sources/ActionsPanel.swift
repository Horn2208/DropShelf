import AppKit
import Combine
import SwiftUI

/// Eigenes kleines Fenster unter der Ablage: Glas nur hinter den Knöpfen, der Rest bleibt durchsichtig.
@MainActor
final class ActionsPanel: NSPanel {
    static let size = CGSize(width: 240, height: 44)
    weak var anchorWindow: NSWindow?
    private var sub: AnyCancellable?

    init(shelf: Shelf) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        let host = NSHostingView(rootView: ActionsView(shelf: shelf, anchor: { [weak self] in self?.contentView }))
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host
        // Unsichtbar = Klicks gehen durch.
        sub = shelf.$hovering.combineLatest(shelf.$items).sink { [weak self] hover, items in
            self?.ignoresMouseEvents = !(hover && !items.isEmpty)
        }
    }
}

private struct ActionsView: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject private var prefs = ActionPrefs.shared
    let anchor: () -> NSView?
    @Namespace private var ns
    @State private var target: ShelfAction?  // Knopf, über dem gerade eine Datei schwebt
    private var visible: Bool { shelf.hovering && !shelf.items.isEmpty }
    private var shown: [ShelfAction] { Array(prefs.enabled.prefix(ActionPrefs.maxActive)) }

    var body: some View {
        let urls = shelf.items.map(\.url)
        GlassGroup(spacing: 14) {
            HStack(spacing: 10) {
                // Ab macOS 26 fließen die Glas-Knöpfe beim Erscheinen ineinander (Morph über glassEffectID).
                if visible || !GlassKit.liquid {
                    ForEach(Array(shown.enumerated()), id: \.element) { i, a in
                        let ok = a.canPerform(urls)
                        button(a, ok: ok).opacity(GlassKit.liquid ? (ok ? 1 : 0.35) : (visible ? (ok ? 1 : 0.35) : 0))
                            .scaleEffect(GlassKit.liquid ? 1 : Motion.scale(0.5, on: visible))
                            .animation(Motion.pop.map { $0.delay(Double(i) * 0.03) }, value: visible)
                    }
                }
            }
            .animation(Motion.bouncy, value: visible)
            .animation(Motion.smooth, value: shown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { shelf.setHover("actions", $0) }
    }

    @ViewBuilder private func button(_ a: ShelfAction, ok: Bool) -> some View {
        let on = target == a
        let b = GlassCircleButton(symbol: a.symbol, size: 34, help: a.help) { a.run(shelf: shelf, anchor: anchor()) }.disabled(!ok)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).opacity(on ? 1 : 0).allowsHitTesting(false))
            .scaleEffect(on && Motion.enabled ? 1.15 : 1)
            .animation(Motion.snappy, value: on)
            .onDrop(of: [.fileURL, .image, .plainText, .url], delegate: ButtonDrop(
                ok: ok && a.acceptsDrop, shelf: shelf,
                enter: { target = a; shelf.setHover("dropbtn", true) },
                exit: { if target == a { target = nil }; shelf.setHover("dropbtn", false) },
                perform: { a.drop($0, shelf: shelf, anchor: anchor()) }))
        if #available(macOS 26, *) { b.glassEffectID(a.rawValue, in: ns) } else { b }
    }
}

/// Drop auf einen Aktionsknopf: Kopieren-Cursor nur, wenn der Dienst verfügbar ist; sonst abgelehnt.
private struct ButtonDrop: DropDelegate {
    let ok: Bool
    let shelf: Shelf
    let enter: () -> Void
    let exit: () -> Void
    let perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool { ok }
    func dropEntered(info: DropInfo) { if ok { enter() } }
    func dropExited(info: DropInfo) { exit() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: ok ? .copy : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        exit()
        return perform(info.itemProviders(for: [.fileURL, .image, .plainText, .url]))
    }
}
