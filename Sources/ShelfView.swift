import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    let close: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            stack
                .frame(maxWidth: .infinity, maxHeight: shelf.expanded ? 130 : .infinity)
            if shelf.expanded {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shelf.items) { item in row(item) }
                    }
                }
            }
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, lineWidth: targeted ? 3 : 0))
        .overlay(alignment: .topLeading) {
            Button(action: close) { Image(systemName: "xmark.circle.fill").imageScale(.large) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .onDrop(of: [.fileURL, .image, .plainText, .url], isTargeted: $targeted) { shelf.drop($0) }
    }

    @ViewBuilder private var stack: some View {
        if shelf.items.isEmpty {
            Text("Dateien hierher ziehen")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            ZStack {
                ForEach(Array(shelf.items.suffix(3).enumerated()), id: \.element.id) { i, item in
                    Thumb(url: item.url)
                        .rotationEffect(.degrees(Double(i - 1) * 6))
                        .offset(x: CGFloat(i - 1) * 8, y: CGFloat(i - 1) * -5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(shelf.items.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 14, y: 14)
            }
            .overlay {
                DragOut(urls: { shelf.items.map(\.url) }, onClick: { shelf.expanded.toggle() },
                        onMoved: { shelf.remove($0) })
            }
        }
    }

    private func row(_ item: Shelf.Item) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 22, height: 22)
            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlay {
            DragOut(urls: { [item.url] }, onRemove: { shelf.remove([item.url]) }, onMoved: { shelf.remove($0) })
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
        Image(nsImage: image)
            .resizable().scaledToFit()
            .frame(width: 110, height: 110)
            .shadow(radius: 3)
            .task(id: url) {
                let req = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: 110, height: 110),
                    scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                    image = rep.nsImage
                }
            }
    }
}
