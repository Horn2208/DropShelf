import AppKit
import SwiftUI

@MainActor
final class ClipboardModel: ObservableObject {
    @Published var query = ""
    @Published var selected = 0
    var anchor = UnitPoint.center  // Mausposition im Panel: von dort wächst es auf

    /// Angepinnte zuerst, dann nach Zeit; Suche filtert sofort.
    func visible(_ all: [ClipEntry]) -> [ClipEntry] {
        let f = query.isEmpty ? all : all.filter { $0.searchText.localizedStandardContains(query) }
        return f.filter(\.pinned) + f.filter { !$0.pinned }
    }
}

/// Glas-Panel „Zwischenablage-Verlauf“ (⌃V) an der Maus. Nicht aktivierend, aber Schlüsselfenster (Tippen im Suchfeld).
@MainActor
final class ClipboardPanel: NSPanel {
    static let size = CGSize(width: 360, height: 440)
    private static var current: ClipboardPanel?
    private let model = ClipboardModel()
    private let mouse: CGPoint
    private let previousApp: NSRunningApplication?
    private var closing = false
    private var outsideClick: Any?

    static func toggle() {
        if let current { current.closeAnimated(); return }
        let p = ClipboardPanel(at: NSEvent.mouseLocation, previous: NSWorkspace.shared.frontmostApplication)
        current = p
        p.show()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private init(at mouse: CGPoint, previous: NSRunningApplication?) {
        self.mouse = mouse
        previousApp = previous
        let vf = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let s = Self.size
        let origin = CGPoint(x: min(max(mouse.x - s.width / 2, vf.minX + 8), vf.maxX - s.width - 8),
                             y: min(max(mouse.y - s.height + 40, vf.minY + 8), vf.maxY - s.height - 8))
        super.init(contentRect: NSRect(origin: origin, size: s), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        model.anchor = UnitPoint(x: min(max((mouse.x - origin.x) / s.width, 0), 1), y: min(max(1 - (mouse.y - origin.y) / s.height, 0), 1))
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let host = NSHostingView(rootView: ClipboardView(model: model, pick: { [weak self] in self?.paste($0) }))
        contentView = GlassKit.wrap(host, radius: ClipboardView.radius)
        GlassKit.retint(contentView)
        DispatchQueue.main.async { self.invalidateShadow() }
    }

    private func show() {
        alphaValue = Motion.userOn ? 0 : 1
        makeKeyAndOrderFront(nil)
        if Motion.userOn {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; $0.timingFunction = Motion.Curve.enter; self.animator().alphaValue = 1 }
        }
        GlassKit.retintSoon(contentView)
        // Klick außerhalb (andere App): schließen.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAnimated() }
        }
    }

    /// Ease-in 0,12 s, dann schließen.
    func closeAnimated() {
        guard !closing else { return }
        closing = true
        guard Motion.userOn else { close(); return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12; c.timingFunction = Motion.Curve.exit; self.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { self.close() } })
    }

    override func close() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        if Self.current === self { Self.current = nil }
        super.close()
    }

    override func resignKey() {
        super.resignKey()
        closeAnimated()
    }

    override func cancelOperation(_ sender: Any?) { closeAnimated() }

    /// Eintrag in die Zwischenablage, Panel zu, vorige App nach vorn und ⌘V (nur mit Bedienungshilfen); sonst „Kopiert“.
    private func paste(_ e: ClipEntry) {
        ClipboardStore.shared.copy(e)
        closing = true
        close()
        previousApp?.activate()
        if AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.postCommandV() }
        } else {
            ClipboardHUD.show("Kopiert", at: mouse)
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
            ev?.flags = .maskCommand
            ev?.post(tap: .cgSessionEventTap)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return super.sendEvent(event) }
        let list = model.visible(ClipboardStore.shared.entries)
        let pick = { (i: Int) in if list.indices.contains(i) { self.paste(list[i]) } }
        if event.modifierFlags.contains(.command), let c = event.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
            pick(n - 1); return
        }
        switch event.keyCode {
        case 126: model.selected = max(model.selected - 1, 0)
        case 125: model.selected = min(model.selected + 1, max(list.count - 1, 0))
        case 36, 76: pick(model.selected)
        case 53: closeAnimated()
        default: super.sendEvent(event)
        }
    }
}

/// Kleines „Kopiert“ neben der Maus (~0,8 s), ohne Fokus.
@MainActor
enum ClipboardHUD {
    private static var panel: NSPanel?

    static func show(_ text: String, at mouse: CGPoint) {
        panel?.close()
        let host = NSHostingView(rootView: Text(text).font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8).glassBG(Capsule()))
        let s = host.fittingSize
        let p = NSPanel(contentRect: NSRect(x: mouse.x + 14, y: mouse.y - s.height - 14, width: s.width, height: s.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                                 completionHandler: { MainActor.assumeIsolated { p.close(); if panel === p { panel = nil } } })
        }
    }
}

struct ClipboardView: View {
    static let radius: CGFloat = 26
    @ObservedObject var model: ClipboardModel
    @ObservedObject private var store = ClipboardStore.shared
    let pick: (ClipEntry) -> Void
    @State private var appeared = false
    @FocusState private var focus: Bool
    @Environment(\.colorScheme) private var scheme

    private var openAnim: Animation? {
        Motion.enabled ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.2) : (Motion.userOn ? .easeOut(duration: 0.15) : nil)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let list = model.visible(store.entries)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Zwischenablage durchsuchen", text: $model.query).textFieldStyle(.plain).font(.system(size: 14)).focused($focus)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 8)

            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 44, weight: .thin)).foregroundStyle(Color.primary.opacity(0.7))
                    Text(store.entries.isEmpty ? "Noch nichts kopiert" : "Keine Treffer").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                                ClipRow(entry: e, index: i, selected: model.selected == i, store: store, pick: pick)
                                    .id(e.id)
                                    .onHover { if $0 { model.selected = i } }
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .onChange(of: model.selected) { i in
                        if list.indices.contains(i) { proxy.scrollTo(list[i].id) }
                    }
                }
            }
        }
        .background { if !GlassKit.liquid { scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.35) } }
        .clipShape(shape)
        .overlay { if !GlassKit.liquid { shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12), lineWidth: 1).allowsHitTesting(false) } }
        .scaleEffect(appeared || !Motion.enabled ? 1 : 0.94, anchor: model.anchor)
        .opacity(appeared ? 1 : 0)
        .animation(openAnim, value: appeared)
        .onAppear { DispatchQueue.main.async { appeared = true; focus = true } }
        .onChange(of: model.query) { _ in model.selected = 0 }
        .onChange(of: list.count) { n in model.selected = min(model.selected, max(n - 1, 0)) }
    }
}

private struct ClipRow: View {
    let entry: ClipEntry
    let index: Int
    let selected: Bool
    let store: ClipboardStore
    let pick: (ClipEntry) -> Void
    @State private var hover = false
    @State private var thumb: NSImage?

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de")
        f.unitsStyle = .abbreviated
        return f
    }()

    private var title: String {
        switch entry.kind {
        case .text, .url: return (entry.text ?? "").split(whereSeparator: \.isNewline).prefix(3).joined(separator: " ")
        case .image: return "Bild \(entry.meta ?? "")"
        case .files:
            let p = entry.paths ?? []
            return p.count == 1 ? (p[0] as NSString).lastPathComponent : "\(p.count) Dateien"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.tail)
                Text([entry.app, Self.formatter.localizedString(for: entry.date, relativeTo: Date())].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { store.togglePin(entry.id) } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin").font(.system(size: 12)).foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).opacity(hover || entry.pinned ? 1 : 0).help(entry.pinned ? "Lösen" : "Anpinnen")
            if index < 9 { Text("⌘\(index + 1)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(selected ? 0.1 : hover ? 0.06 : 0)))
        .animation(Motion.userOn ? .easeOut(duration: 0.12) : nil, value: hover)
        .contentShape(Rectangle())
        .onTapGesture { pick(entry) }
        .onHover { hover = $0 }
        .onDrag { provider }
        .task(id: entry.image) {
            if let u = store.imageURL(entry) { thumb = Self.thumbnail(u) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch entry.kind {
        case .image:
            if let thumb { Image(nsImage: thumb).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6)) }
            else { Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(.secondary) }
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.paths?.first ?? "/")).resizable().scaledToFit()
        case .url: Image(systemName: "link").font(.system(size: 18)).foregroundStyle(.secondary)
        case .text: Image(systemName: "text.alignleft").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    /// Ziehen: Text/Link als Text, Bild als PNG-Datei, Dateien als Datei-URL (auch auf eine Ablage).
    private var provider: NSItemProvider {
        switch entry.kind {
        case .text: return NSItemProvider(object: (entry.text ?? "") as NSString)
        case .url: return (entry.text.flatMap(URL.init(string:)).map { NSItemProvider(object: $0 as NSURL) }) ?? NSItemProvider(object: (entry.text ?? "") as NSString)
        case .image: return store.imageURL(entry).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        case .files: return (entry.paths?.first).map { NSItemProvider(object: URL(fileURLWithPath: $0) as NSURL) } ?? NSItemProvider()
        }
    }

    private static let cache = NSCache<NSString, NSImage>()
    private static func thumbnail(_ url: URL) -> NSImage? {
        if let c = cache.object(forKey: url.path as NSString) { return c }
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                  kCGImageSourceThumbnailMaxPixelSize: 72] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        cache.setObject(img, forKey: url.path as NSString)
        return img
    }
}
