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

/// Auswahl wie im Finder: Klick = nur diese, Cmd = umschalten, Shift = Bereich ab dem Anker (in Anzeige-Reihenfolge).
struct Selection: Equatable {
    var ids: Set<UUID> = []
    var anchor: UUID?
    /// Anzeige-Reihenfolge (Sortierung der Detail-Ansicht); verschwundene Einträge fallen aus der Auswahl.
    var order: [UUID] = [] {
        didSet {
            ids.formIntersection(order)
            if let a = anchor, !order.contains(a) { anchor = nil }
        }
    }

    mutating func click(_ id: UUID, command: Bool = false, shift: Bool = false) {
        if shift, let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            let range = Set(order[min(i, j)...max(i, j)])
            ids = command ? ids.union(range) : range  // Anker bleibt (Finder)
        } else if command {
            if ids.remove(id) == nil { ids.insert(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }

    mutating func clear() { ids = []; anchor = nil }

    /// Pfeiltasten: vorige/nächste Datei allein auswählen (ohne Auswahl: erste bzw. letzte).
    mutating func step(_ d: Int) {
        guard !order.isEmpty else { return }
        let i = anchor.flatMap { order.firstIndex(of: $0) }.map { min(max($0 + d, 0), order.count - 1) } ?? (d > 0 ? 0 : order.count - 1)
        click(order[i])
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
                Group {
                    if mode == "grid" {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 8)], spacing: 8) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { DetailCell(shelf: shelf, item: $1, index: $0, grid: true) }
                        }
                    } else {
                        LazyVStack(spacing: 2) { ForEach(Array(items.enumerated()), id: \.element.id) { DetailCell(shelf: shelf, item: $1, index: $0, grid: false) } }
                    }
                }
                // Freie Fläche im Raster/der Liste: Klick hebt die Auswahl auf, Ziehen verschiebt das Fenster (wie sonst auf Glas).
                .frame(maxWidth: .infinity, minHeight: ShelfPanel.detailSize.height - 70, alignment: .top)
                .background { WindowDragArea { shelf.selection.clear() } }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .onChange(of: items.map(\.id), initial: true) { _, ids in shelf.selection.order = ids }
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
    @ObservedObject var shelf: Shelf
    let item: Shelf.Item
    let index: Int
    let grid: Bool
    @State private var hover = false
    @State private var faded = false  // sanftes Einblenden der ersten Zellen, ohne Bewegung
    @State private var meta = ""

    private var selected: Bool { shelf.selection.ids.contains(item.id) }
    /// Finder-Markierung: graue Kachel (Raster: um die Vorschau, Liste: ganze Zeile).
    private var tile: some View { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(selected ? 0.14 : 0)) }

    var body: some View {
        Group {
            if grid {
                VStack(spacing: 4) {
                    Thumb(url: item.url, maxW: 96, maxH: 80).frame(width: 104, height: 88).background(tile).allowsHitTesting(false)
                    label(.center)
                }
                .padding(8).frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    Thumb(url: item.url, maxW: 32, maxH: 32, shadow: false).frame(width: 36, height: 36).allowsHitTesting(false)
                    label(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 46)
                .background(tile)
            }
        }
        // Hinter dem Inhalt (statt darüber), damit Name und Endung klickbar bleiben; Vorschau und Texte lassen Klicks durch.
        // Klick wählt aus (Cmd/Shift wie im Finder) und gibt dem Panel die Tastatur (Leertaste = Quick Look, Pfeile, Esc).
        .background {
            DragOut(urls: { [item.url] }, onClick: { select() }, onRemove: { shelf.remove([item.url]) },
                    onAirDrop: { AirDropSender.shared.send(shelf: shelf, urls: [item.url]) },
                    convertItem: { ConvertMenu.menuItem(for: item.url, shelf: shelf) },  // nur die angeklickte Datei
                    editItem: { EditMenu.menuItem(for: EditMenu.targetURLs(clicked: item.id, selection: shelf.selection, items: shelf.items), shelf: shelf) },
                    onDragging: { shelf.setHover("dragout", $0) }, onMoved: { shelf.remove($0) })
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
    }

    private func select() {
        let m = NSEvent.modifierFlags
        shelf.selection.click(item.id, command: m.contains(.command), shift: m.contains(.shift))
        ShelfPanel.focus(shelf)
    }

    private func label(_ a: HorizontalAlignment) -> some View {
        VStack(alignment: a, spacing: 1) {
            NameField(url: item.url, shelf: shelf, selected: selected, lines: grid && selected ? 2 : 1) {
                if !selected { shelf.selection.click(item.id) }
            }
            Text(meta).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).allowsHitTesting(false)
        }
    }
}
