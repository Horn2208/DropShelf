import AppKit
import SwiftUI

@MainActor
final class HistoryModel: ObservableObject {
    @Published var selected = 0
}

/// Glas-Panel „Verlauf“ an der Mausposition: Pfeiltasten, Enter, Esc; schließt beim Verlust des Fokus.
@MainActor
final class HistoryPanel: NSPanel {
    static let size = CGSize(width: 320, height: 400)
    private static var current: HistoryPanel?
    private let model = HistoryModel()
    private let mouse: CGPoint
    private var confirming = false  // Rückfrage offen: Fokusverlust nicht als „Klick außerhalb“ werten

    /// Öffnet das Panel (ein zweiter Aufruf schließt es wieder).
    static func toggle() {
        if let current { current.close(); return }
        let p = HistoryPanel(at: NSEvent.mouseLocation)
        current = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private init(at mouse: CGPoint) {
        self.mouse = mouse
        let vf = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let s = Self.size
        let origin = CGPoint(x: min(max(mouse.x - s.width / 2, vf.minX + 8), vf.maxX - s.width - 8),
                             y: min(max(mouse.y - s.height + 40, vf.minY + 8), vf.maxY - s.height - 8))
        super.init(contentRect: NSRect(origin: origin, size: s), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let host = NSHostingView(rootView: HistoryView(model: model, restore: { [weak self] in self?.restore($0) },
                                                       airDrop: { [weak self] in self?.close(); AirDropSender.shared.send(shelf: nil, urls: $0.urls) },
                                                       clear: { [weak self] in self?.confirmClear() }))
        contentView = GlassKit.wrap(host, radius: HistoryView.radius)
        GlassKit.retint(contentView)
        DispatchQueue.main.async { self.invalidateShadow() }
    }

    private func restore(_ e: HistoryStore.Entry) {
        close()
        ShelfManager.shared.restore(e, at: mouse)
    }

    private func confirmClear() {
        confirming = true
        let a = NSAlert()
        a.messageText = "Verlauf leeren?"
        a.informativeText = "Alle gespeicherten Ablagen werden aus dem Verlauf gelöscht."
        a.addButton(withTitle: "Leeren").hasDestructiveAction = true
        a.addButton(withTitle: "Abbrechen")
        let ok = a.runModal() == .alertFirstButtonReturn
        confirming = false
        if ok { HistoryStore.shared.clear() }
        makeKeyAndOrderFront(nil)
    }

    override func resignKey() {
        super.resignKey()
        if !confirming { close() }
    }

    override func close() {
        Self.current = nil
        super.close()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return super.sendEvent(event) }
        let entries = HistoryStore.shared.entries
        switch event.keyCode {
        case 126: model.selected = max(model.selected - 1, 0)
        case 125: model.selected = min(model.selected + 1, max(entries.count - 1, 0))
        case 36, 76: if entries.indices.contains(model.selected) { restore(entries[model.selected]) }
        case 53: close()
        default: super.sendEvent(event)
        }
    }
}

struct HistoryView: View {
    static let radius: CGFloat = 26
    @ObservedObject var model: HistoryModel
    @ObservedObject private var store = HistoryStore.shared
    let restore: (HistoryStore.Entry) -> Void
    let airDrop: (HistoryStore.Entry) -> Void
    let clear: () -> Void
    @State private var appeared = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(spacing: 0) {
            HStack {
                Text("Verlauf").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(store.entries.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 44, weight: .thin))
                        .foregroundStyle(Color.primary.opacity(0.7))
                    Text("Noch kein Verlauf").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(store.entries.enumerated()), id: \.element.id) { i, e in
                                HistoryRow(entry: e, selected: model.selected == i, restore: restore, airDrop: airDrop)
                                    .id(e.id)
                                    .onHover { if $0 { model.selected = i } }
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 12)
                                    .animation(Motion.smooth.map { $0.delay(Double(min(i, 8)) * 0.04) }, value: appeared)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    .onChange(of: model.selected) { i in
                        if store.entries.indices.contains(i) { withAnimation(Motion.snappy) { proxy.scrollTo(store.entries[i].id) } }
                    }
                }
            }

            Button("Verlauf leeren", action: clear)
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                .disabled(store.entries.isEmpty)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .background {
            if !GlassKit.liquid { scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.35) }
        }
        .clipShape(shape)
        .overlay { if !GlassKit.liquid { shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12), lineWidth: 1).allowsHitTesting(false) } }
        .scaleEffect(appeared || !Motion.enabled ? 1 : 0.92)
        .animation(Motion.pop, value: appeared)
        .onAppear { DispatchQueue.main.async { appeared = true } }
        .onChange(of: store.entries.count) { n in model.selected = min(model.selected, max(n - 1, 0)) }
    }
}

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    let selected: Bool
    let restore: (HistoryStore.Entry) -> Void
    let airDrop: (HistoryStore.Entry) -> Void

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de")
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        let shown = Array(entry.urls.prefix(3))
        HStack(spacing: 12) {
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, url in
                    let d = CGFloat(i - (shown.count - 1)) * 3
                    Thumb(url: url, maxW: 36, maxH: 36, shadow: false).offset(x: d, y: -d)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(Self.formatter.localizedString(for: entry.date, relativeTo: Date()))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(selected ? 0.1 : 0)))
        .animation(Motion.snappy, value: selected)
        .overlay {
            DragOut(urls: { entry.urls }, onClick: { restore(entry) },
                    onRemove: { HistoryStore.shared.remove(entry.id) },
                    onAirDrop: { airDrop(entry) }, onRestore: { restore(entry) },
                    removeTitle: "Aus Verlauf löschen",
                    onMoved: { _ in HistoryStore.shared.remove(entry.id, deleteFiles: false) })
        }
    }
}
