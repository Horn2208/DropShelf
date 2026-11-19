import AppKit
import Combine
import SwiftUI

enum ShelfAction: CaseIterable {
    case airdrop, message, mail, share

    var symbol: String {
        switch self {
        case .airdrop: "dot.radiowaves.up.forward"
        case .message: "message"
        case .mail: "envelope"
        case .share: "square.and.arrow.up"
        }
    }
    var help: String {
        switch self {
        case .airdrop: "Per AirDrop senden (⌃⌥A)"
        case .message: "Per Nachrichten senden"
        case .mail: "Per Mail senden"
        case .share: "Teilen…"
        }
    }
    private var serviceName: NSSharingService.Name? {
        switch self {
        case .airdrop: .sendViaAirDrop
        case .message: .composeMessage
        case .mail: .composeEmail
        case .share: nil
        }
    }

    @MainActor func canPerform(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        guard let name = serviceName else { return true }
        return NSSharingService(named: name)?.canPerform(withItems: urls) ?? false
    }

    @MainActor func run(shelf: Shelf, anchor: NSView?) {
        let urls = shelf.items.map(\.url)
        if self == .airdrop { AirDropSender.shared.send(shelf: shelf, urls: urls); return }
        NSApp.activate(ignoringOtherApps: true)  // nonactivating Panel: Teilen-Dialog braucht aktive App
        if let name = serviceName { NSSharingService(named: name)?.perform(withItems: urls) }
        else if let anchor { NSSharingServicePicker(items: urls).show(relativeTo: .zero, of: anchor, preferredEdge: .minY) }
    }
}

/// Eigenes kleines Fenster unter der Ablage: Glas nur hinter den Knöpfen, der Rest bleibt durchsichtig.
@MainActor
final class ActionsPanel: NSPanel {
    static let size = CGSize(width: 190, height: 40)
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
    let anchor: () -> NSView?
    private var visible: Bool { shelf.hovering && !shelf.items.isEmpty }

    var body: some View {
        let urls = shelf.items.map(\.url)
        HStack(spacing: 10) {
            ForEach(Array(ShelfAction.allCases.enumerated()), id: \.element) { i, a in
                let ok = a.canPerform(urls)
                GlassCircleButton(symbol: a.symbol, size: 34, help: a.help) { a.run(shelf: shelf, anchor: anchor()) }
                    .opacity(visible ? (ok ? 1 : 0.35) : 0)
                    .disabled(!ok)
                    .scaleEffect(Motion.scale(0.5, on: visible))
                    .animation(Motion.pop.map { $0.delay(Double(i) * 0.03) }, value: visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onHover { shelf.setHover("actions", $0) }
    }
}
