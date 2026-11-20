import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum FileInfo {
    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension))?.conforms(to: .image) ?? false
    }

    /// Pixelmaße aus den Bild-Metadaten, ohne Volldekodierung.
    static func pixels(_ url: URL) -> CGSize? {
        guard isImage(url), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func subtitle(_ url: URL) -> String {
        var s = bytes(size(url))
        if let p = pixels(url) { s += " • \(Int(p.width))×\(Int(p.height))" }
        return s
    }

    static func title(_ urls: [URL]) -> String {
        if urls.count == 1 { return isImage(urls[0]) ? "1 Bild" : "1 Datei" }
        return "\(urls.count) Dateien"
    }
}

private enum SortKey: String, CaseIterable {
    case added = "Hinzugefügt", name = "Name", size = "Größe"
}

/// Aufgeklappte Ansicht im selben Panel: Kopfzeile, Raster oder Liste.
struct DetailView: View {
    @ObservedObject var shelf: Shelf
    let ns: Namespace.ID
    let back: () -> Void
    @AppStorage("viewMode") private var mode = "grid"
    @State private var sort = SortKey.added

    private var items: [Shelf.Item] {
        switch sort {
        case .added: return shelf.items
        case .name: return shelf.items.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        case .size: return shelf.items.sorted { FileInfo.size($0.url) > FileInfo.size($1.url) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if mode == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 8)], spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { DetailCell(shelf: shelf, item: $1, index: $0, grid: true) }
                    }
                } else {
                    LazyVStack(spacing: 2) { ForEach(Array(items.enumerated()), id: \.element.id) { DetailCell(shelf: shelf, item: $1, index: $0, grid: false) } }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    private var header: some View {
        let urls = shelf.items.map(\.url)
        return HStack(spacing: 10) {
            GlassCircleButton(symbol: "chevron.left", help: "Zurück", action: back)
            VStack(alignment: .leading, spacing: 1) {
                Text(FileInfo.title(urls)).font(.system(size: 14, weight: .semibold))
                    .contentTransition(.numericText()).animation(Motion.smooth, value: urls.count)
                Text(FileInfo.bytes(urls.reduce(0) { $0 + FileInfo.size($1) }))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Sortieren", selection: $sort) { ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.inline)
            } label: { GlassCircleLabel(symbol: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Sortieren")
            HStack(spacing: 0) {
                modeButton("square.grid.2x2", "grid", "Raster")
                modeButton("list.bullet", "list", "Liste")
            }
            .padding(2)
            .glassBG(Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }

    private func modeButton(_ symbol: String, _ value: String, _ help: String) -> some View {
        Button { withAnimation(Motion.snappy) { mode = value } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(mode == value ? 0.95 : 0.55))
                .frame(width: 30, height: 20)
                .background(Capsule().fill(Color.primary.opacity(mode == value ? 0.16 : 0)))
        }
        .buttonStyle(.plain).help(help)
    }
}

private struct DetailCell: View {
    let shelf: Shelf
    let item: Shelf.Item
    let index: Int
    let grid: Bool
    @State private var hover = false
    @State private var faded = false  // sanftes Einblenden der ersten Zellen, ohne Bewegung
    @State private var meta = ""

    var body: some View {
        Group {
            if grid {
                VStack(spacing: 4) {
                    Thumb(url: item.url, maxW: 96, maxH: 80).frame(height: 84)
                    label(.center)
                }
                .padding(8).frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    Thumb(url: item.url, maxW: 32, maxH: 32, shadow: false).frame(width: 36, height: 36)
                    label(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 46)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .opacity(faded || index >= 6 || !Motion.enabled ? 1 : 0)
        .onAppear {
            // Erste 6 Zellen: 20 ms versetzt, je 0,1 s Fade (zusammen ≤ 0,2 s); der Rest blendet mit dem Fenster ein.
            guard Motion.enabled else { return }
            withAnimation(.easeOut(duration: 0.1).delay(0.08 + Double(index) * 0.02)) { faded = true }
        }
        .onHover { hover = $0 }
        .task(id: item.url) { meta = FileInfo.subtitle(item.url) }
        .overlay {
            DragOut(urls: { [item.url] }, onRemove: { shelf.remove([item.url]) },
                    onAirDrop: { AirDropSender.shared.send(shelf: shelf, urls: [item.url]) },
                    onDragging: { shelf.setHover("dragout", $0) }, onMoved: { shelf.remove($0) })
        }
    }

    private func label(_ a: HorizontalAlignment) -> some View {
        VStack(alignment: a, spacing: 1) {
            Text(item.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(meta).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
