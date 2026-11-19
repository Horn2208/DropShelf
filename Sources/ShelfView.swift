import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    let close: () -> Void
    @State private var targeted = false
    @Environment(\.colorScheme) private var scheme
    static let animationDuration = 0.22
    static let radius: CGFloat = 26
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: Self.animationDuration) }
    private var edge: Color { scheme == .dark ? .white.opacity(0.18) : .black.opacity(0.12) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack {
            WindowDragArea()
            VStack(spacing: 0) {
                topBar
                content
                if shelf.expanded {
                    ScrollView {
                        LazyVStack(spacing: 2) { ForEach(shelf.items) { Row(shelf: shelf, item: $0) } }
                            .padding(.horizontal, 10).padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(width: ShelfPanel.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .top) {
            // Nur leichte Grau-Tönung über dem Glas, oben ein dezenter Glanz.
            ZStack(alignment: .top) {
                Color(white: scheme == .dark ? 0.25 : 0.92).opacity(0.3)
                LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: ShelfPanel.collapsedHeight / 3)
            }
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(targeted ? Color.accentColor : edge, lineWidth: targeted ? 2.5 : 1).allowsHitTesting(false))
        .animation(animation, value: shelf.expanded)
        .animation(animation, value: targeted)
        .onHover { shelf.setHover("main", $0) }
        .onDrop(of: [.fileURL, .image, .plainText, .url], isTargeted: $targeted) { shelf.drop($0) }
    }

    private var topBar: some View {
        HStack {
            RoundButton(symbol: "xmark", help: "Schließen", action: close)
            Spacer()
            if shelf.items.isEmpty {
                Color.clear.frame(width: 28, height: 28)
            } else {
                RoundButton(symbol: shelf.expanded ? "chevron.up" : "chevron.down",
                            help: shelf.expanded ? "Liste einklappen" : "Liste aufklappen") { shelf.expanded.toggle() }
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
                Text("Dateien hierher ziehen").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .scaleEffect(targeted && !reduceMotion ? 1.03 : 1)
        } else {
            VStack(spacing: 10) {
                stack
                nameCapsule
            }
            .frame(maxHeight: shelf.expanded ? 170 : .infinity)
            .scaleEffect(targeted && !reduceMotion ? 1.03 : 1)
        }
    }

    private var stack: some View {
        let shown = Array(shelf.items.suffix(3))
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                let d = CGFloat(i - (shown.count - 1)) * 3  // ältere Dateien liegen leicht versetzt dahinter
                Thumb(url: item.url).offset(x: d, y: -d).allowsHitTesting(false)
            }
        }
        .frame(width: 120, height: 120)
        .overlay {
            DragOut(urls: { shelf.items.map(\.url) }, onClick: { shelf.expanded.toggle() }, onMoved: { shelf.remove($0) })
        }
    }

    private var nameCapsule: some View {
        let n = shelf.items.count
        return Button { shelf.expanded.toggle() } label: {
            HStack(spacing: 5) {
                Text(n == 1 ? shelf.items[0].url.lastPathComponent : "\(n) Dateien")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(shelf.expanded ? 180 : 0))
            }
            .foregroundStyle(Color.primary.opacity(0.9))
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(Color.primary.opacity(0.12)))
            .frame(maxWidth: 170)
        }
        .buttonStyle(.plain)
    }
}

private struct RoundButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.2 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct Row: View {
    let shelf: Shelf
    let item: Shelf.Item
    @State private var hover = false

    private var size: String {
        let b = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return b.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "–"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(size).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
        .overlay {
            DragOut(urls: { [item.url] }, onRemove: { shelf.remove([item.url]) },
                    onAirDrop: { AirDropSender.shared.send(shelf: shelf, urls: [item.url]) }, onMoved: { shelf.remove($0) })
        }
    }
}

private struct Thumb: View {
    let url: URL
    @State private var image: NSImage

    init(url: URL) {
        self.url = url
        _image = State(initialValue: NSWorkspace.shared.icon(forFile: url.path))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Image(nsImage: image)
            .resizable().scaledToFit()
            .frame(maxWidth: 104, maxHeight: 104)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .task(id: url) {
                let req = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: 104, height: 104),
                    scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                    image = rep.nsImage
                }
            }
    }
}
