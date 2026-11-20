import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    let close: () -> Void
    @State private var targeted = false
    @AppStorage("glassIntensity") private var glass = 0.4
    @Environment(\.colorScheme) private var scheme
    @Namespace private var ns  // Vorschau „fliegt“ ins Raster der Detail-Ansicht
    static let animationDuration = 0.22
    static let radius: CGFloat = 26
    private var edge: Color { scheme == .dark ? .white.opacity(0.2) : .black.opacity(0.12) }
    private var detail: Bool { shelf.expanded && !shelf.items.isEmpty }
    private var shown: Bool { shelf.appeared && !shelf.closing }
    /// Wechsel klein ↔ groß: Inhalt blobbt kurz mit (0,96 → 1), bei reduzierter Bewegung nur Fade.
    private var swap: AnyTransition { Motion.enabled ? .scale(scale: 0.96).combined(with: .opacity) : .opacity }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack {
            WindowDragArea()
            Group {
                if detail {
                    DetailView(shelf: shelf, ns: ns) { shelf.expanded = false }
                        .transition(swap)
                } else {
                    VStack(spacing: 0) {
                        topBar
                        content
                    }
                    .transition(swap)
                }
            }
            .popScale(shown: shown, closing: shelf.closing)
            .scaleEffect(targeted && Motion.enabled ? 1.03 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .top) {
            // Ohne Liquid Glass: nur leichte Tönung über dem Glas (Stärke per Einstellung), oben ein dezenter Glanz.
            let tint = 0.05 + 0.3 * glass
            if !GlassKit.liquid {
                ZStack(alignment: .top) {
                    (scheme == .dark ? Color.black.opacity(tint) : Color.white.opacity(tint * 1.5))
                    LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 90)
                }
                .allowsHitTesting(false)
            } else {
                // Liquid Glass: Mitte dunkel getönt (Regler), der Rand bleibt frei für die Lichtbrechung.
                shape.fill(Color.black.opacity(0.5 * glass)).padding(20).blur(radius: 14).allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(targeted ? Color.accentColor : (GlassKit.liquid ? .clear : edge), lineWidth: targeted ? 2.5 : 1).allowsHitTesting(false))
        .animation(Motion.pop, value: detail)
        .animation(Motion.smooth, value: shelf.items.isEmpty)
        .animation(Motion.snappy, value: targeted)
        .onHover { shelf.setHover("main", $0) }
        .onDrop(of: [.fileURL, .image, .plainText, .url], isTargeted: $targeted) { shelf.drop($0) }
    }

    private var topBar: some View {
        HStack {
            GlassCircleButton(symbol: "xmark", help: "Schließen", action: close)
            Spacer()
            if shelf.items.isEmpty {
                Color.clear.frame(width: 28, height: 28)
            } else {
                GlassCircleButton(symbol: "chevron.down", help: "Details öffnen") { shelf.expanded = true }
            }
        }
        .overlay { Capsule().fill(Color.primary.opacity(0.25)).frame(width: 36, height: 5).allowsHitTesting(false) }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder private var content: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 44, weight: .thin))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .bounceSymbol(targeted)
                Text("Dateien hierher ziehen").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        } else {
            VStack(spacing: 10) {
                stack
                nameCapsule
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var stack: some View {
        let shown = Array(shelf.items.suffix(3))
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                let d = CGFloat(i - (shown.count - 1)) * 3  // ältere Dateien liegen 3 pt versetzt dahinter
                Thumb(url: item.url, maxW: 100, maxH: 104).matchedGeometryEffect(id: item.id, in: ns).offset(x: d, y: -d).allowsHitTesting(false)
                    .transition(Motion.enabled ? .scale(scale: 0.6).combined(with: .opacity) : .opacity)
            }
        }
        .animation(Motion.pop, value: shelf.items.count)
        .frame(width: 120, height: 116)
        .overlay {
            DragOut(urls: { shelf.items.map(\.url) }, onClick: { shelf.expanded = true }, onMoved: { shelf.remove($0) })
        }
    }

    private var nameCapsule: some View {
        let n = shelf.items.count
        let label = n == 1 ? shelf.items[0].url.lastPathComponent : "\(n) Dateien"
        return Button { shelf.expanded = true } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).bounceSymbol(n)
            }
            .foregroundStyle(Color.primary.opacity(0.9))
            .padding(.horizontal, 12).frame(height: 26)
            .glassBG(Capsule(), line: 0.5)
            .frame(maxWidth: 170)
            .animation(Motion.smooth, value: label)
        }
        .buttonStyle(.plain)
    }
}

/// Freie Vorschau (keine Fläche dahinter): Bild exakt eingepasst, Ecken, feiner Rand, Schatten.
struct Thumb: View {
    let url: URL
    var maxW: CGFloat = 110
    var maxH: CGFloat = 130
    var shadow = true
    @State private var image: NSImage
    @State private var loaded = false

    init(url: URL, maxW: CGFloat = 110, maxH: CGFloat = 130, shadow: Bool = true) {
        self.url = url; self.maxW = maxW; self.maxH = maxH; self.shadow = shadow
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        _image = State(initialValue: icon)
    }

    private var fitted: CGSize {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let k = min(maxW / s.width, maxH / s.height, 1.5)
        return CGSize(width: s.width * k, height: s.height * k)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Image(nsImage: image)
            .resizable()
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(loaded ? 0.15 : 0), lineWidth: 0.5))
            .shadow(color: .black.opacity(shadow && loaded ? 0.28 : 0), radius: 6, y: 2)
            .task(id: url) {
                let req = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: maxW, height: maxH),
                    scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                    image = rep.nsImage
                    loaded = true
                }
            }
    }
}
