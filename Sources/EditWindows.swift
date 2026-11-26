import AppKit
import AVFoundation
import PDFKit
import SwiftUI

// MARK: - Seiten verwalten

/// Zustand des Seiten-Fensters (ohne Fenster testbar). Geändert wird nur das geladene Dokument, nie die Quelldatei.
@MainActor final class PDFPagesModel: ObservableObject {
    /// Eine Seite in aktueller Reihenfolge; Index = Seitenindex im Dokument.
    struct Page: Identifiable, Equatable { let id: UUID; var rotation: Int }

    let source: URL
    private let doc: PDFDocument
    @Published private(set) var pages: [Page] { didSet { selection.order = pages.map(\.id) } }
    @Published var selection = Selection()
    @Published var message = ""  // Rückmeldung im Fenster („Auszug gespeichert“, Fehler)
    private var saved: [Page]

    init(url: URL) throws {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { throw PDFToolsError.unreadable }
        source = url
        self.doc = doc
        let pages = (0..<doc.pageCount).map { Page(id: UUID(), rotation: doc.page(at: $0)?.rotation ?? 0) }
        self.pages = pages
        saved = pages
        selection.order = pages.map(\.id)
    }

    /// Ausgewählte Seitenindizes, aufsteigend.
    var selected: [Int] { pages.indices.filter { selection.ids.contains(pages[$0].id) } }
    /// Abweichung vom gespeicherten Stand (zurückgedreht oder zurückgeschoben zählt nicht).
    var isDirty: Bool { pages != saved }
    /// Nie alle Seiten.
    var canDelete: Bool { !selected.isEmpty && selected.count < pages.count }

    func page(at i: Int) -> PDFPage? { doc.page(at: i) }

    func rotate(by degrees: Int) {
        for i in selected {
            PDFTools.rotate(page: i, by: degrees, in: doc)
            pages[i].rotation = doc.page(at: i)?.rotation ?? 0
        }
    }

    /// Geht mindestens eine ausgewählte Seite um eins nach vorn (-1) bzw. hinten (1)?
    func canMove(_ d: Int) -> Bool {
        selected.contains { pages.indices.contains($0 + d) && !selection.ids.contains(pages[$0 + d].id) }
    }

    /// Verschiebt jede ausgewählte Seite um eins; ihre Reihenfolge untereinander bleibt, am Rand bleiben sie stehen.
    func move(_ d: Int) {
        for i in d < 0 ? selected : selected.reversed() {
            let j = i + d
            guard pages.indices.contains(j), !selection.ids.contains(pages[j].id),
                  PDFTools.move(from: i, to: j, in: doc) else { continue }
            pages.swapAt(i, j)
        }
    }

    func delete() {
        guard canDelete else { return }
        let gone = IndexSet(selected)
        PDFTools.delete(pages: gone, in: doc)
        pages = pages.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
    }

    // ponytail: Schreiben läuft auf dem Hauptthread (PDFDocument ist nicht Sendable); bei sehr großen PDFs hakt kurz das Fenster.
    /// Ausgewählte Seiten (mit den aktuellen Änderungen) als eigene PDF.
    func extract(cacheDir: URL = Shelf.cacheDir) throws -> FileOutput.Placement {
        try PDFTools.save(PDFTools.extract(pages: selected, from: doc), for: source, suffix: "Auszug", cacheDir: cacheDir)
    }

    func save(cacheDir: URL = Shelf.cacheDir) throws -> FileOutput.Placement {
        let p = try PDFTools.save(doc, for: source, cacheDir: cacheDir)
        saved = pages
        return p
    }
}

private struct PagesView: View {
    @ObservedObject var model: PDFPagesModel
    let extract: () -> Void
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 12)], spacing: 12) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { i, p in
                        PageCell(model: model, page: p, number: i + 1)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.selection.clear() })
            }
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Button("Links drehen") { model.rotate(by: -90) }.disabled(model.selected.isEmpty)
                    Button("Rechts drehen") { model.rotate(by: 90) }.disabled(model.selected.isEmpty)
                    Button("Nach vorn") { model.move(-1) }.disabled(!model.canMove(-1))
                    Button("Nach hinten") { model.move(1) }.disabled(!model.canMove(1))
                    Button("Löschen") { model.delete() }.disabled(!model.canDelete)
                        .keyboardShortcut(.delete, modifiers: [])
                    Spacer()
                }
                HStack {
                    Button("Auswahl extrahieren", action: extract).disabled(model.selected.isEmpty)
                    Text(model.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(model.message)
                    Spacer()
                    Button("Abbrechen", action: cancel).keyboardShortcut(.cancelAction)
                    Button("Speichern", action: save).keyboardShortcut(.defaultAction).disabled(!model.isDirty)
                }
            }
            .padding(12)
        }
    }
}

private struct PageCell: View {
    @ObservedObject var model: PDFPagesModel
    let page: PDFPagesModel.Page
    let number: Int
    @State private var image: NSImage?

    var body: some View {
        let selected = model.selection.ids.contains(page.id)
        VStack(spacing: 4) {
            ZStack {
                if let image { Image(nsImage: image).resizable().scaledToFit().shadow(radius: 2) }
            }
            .frame(width: 110, height: 140)
            Text("\(number)").font(.system(size: 11)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? Color.accentColor : .clear))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(selected ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            let m = NSEvent.modifierFlags
            model.selection.click(page.id, command: m.contains(.command), shift: m.contains(.shift))
        }
        .accessibilityElement()
        .accessibilityLabel("Seite \(number)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // ponytail: Miniatur wird beim Erscheinen auf dem Hauptthread gerendert; Zwischenspeicher, falls Scrollen hakt.
        .task(id: page.rotation) { image = model.page(at: number - 1)?.thumbnail(of: CGSize(width: 220, height: 280), for: .mediaBox) }
    }
}

// MARK: - Kürzen

/// Ablauf des Kürzen-Fensters: Genau eine Reaktion der `TrimView` zählt, danach schließt das Fenster
/// (`onCancel` kann beim Abbau der View erneut kommen).
@MainActor final class TrimSession {
    private let start: (CMTimeRange) -> Void
    private let report: (String) -> Void
    private let close: () -> Void
    private var finished = false

    init(start: @escaping (CMTimeRange) -> Void, report: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.start = start; self.report = report; self.close = close
    }

    func trim(_ range: CMTimeRange) { finish { start(range) } }
    func cancel() { finish {} }
    func fail(_ message: String) { finish { report(message) } }

    private func finish(_ action: () -> Void) {
        guard !finished else { return }
        finished = true
        action()
        close()
    }
}

// MARK: - Fenster

/// Eigenes Fenster je Datei und Werkzeug (Muster `SettingsOpener`). Hält den Dateizugriff, solange es offen ist,
/// und baut beim Schließen View (samt Player) ab.
@MainActor final class EditWindow: NSObject, NSWindowDelegate {
    enum Tool: String { case pages, trim }
    private static var open: [String: EditWindow] = [:]

    /// Ablage, in die Ergebnisse kommen (die, aus der zuletzt geöffnet wurde; ist sie zu, siehe `ShelfManager.target`).
    private var shelf: Shelf
    private let url: URL
    private let key: String
    private let scoped: Bool
    private var window: NSWindow?
    private var host: NSHostingController<AnyView>?
    private var shouldClose: () -> Bool = { true }

    private init(url: URL, key: String, shelf: Shelf) {
        self.url = url; self.key = key; self.shelf = shelf
        scoped = url.startAccessingSecurityScopedResource()
    }

    static func openPages(_ url: URL, shelf: Shelf) {
        show(.pages, url, shelf, size: NSSize(width: 720, height: 560), min: NSSize(width: 600, height: 380)) { w in
            let model = try PDFPagesModel(url: url)
            w.shouldClose = { !model.isDirty || confirmDiscard() }
            return AnyView(PagesView(model: model, extract: { [weak w] in
                do {
                    let p = try model.extract()
                    w?.deliver(.init(p, for: url))
                    model.message = "Auszug gespeichert: \(p.url.lastPathComponent)"
                } catch { model.message = "Extrahieren fehlgeschlagen: \(error.localizedDescription)" }
            }, save: { [weak w] in
                do {
                    w?.deliver(.init(try model.save(), for: url))
                    w?.window?.close()
                } catch { model.message = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
            }, cancel: { [weak w] in w?.window?.performClose(nil) }))
        }
    }

    static func openTrim(_ url: URL, shelf: Shelf) {
        show(.trim, url, shelf, size: NSSize(width: 640, height: 420), min: NSSize(width: 480, height: 240)) { w in
            let session = TrimSession(start: { [weak w] range in
                guard let w else { return }
                let started = ConvertJobs.shared.run([url], shelf: ShelfManager.shared.target(for: w.shelf),
                                                     failure: "Kürzen fehlgeschlagen") { try await EditMenu.trimJob(url, range: range) }
                if !started { alert("„\(url.lastPathComponent)“ wird gerade bearbeitet. Bitte danach erneut kürzen.") }
            }, report: { alert($0) }, close: { [weak w] in w?.window?.close() })
            return AnyView(TrimView(url: url, onTrim: { session.trim($0) }, onCancel: { session.cancel() },
                                    onError: { session.fail($0) }))
        }
    }

    private static func show(_ tool: Tool, _ url: URL, _ shelf: Shelf, size: NSSize, min: NSSize,
                             content: (EditWindow) throws -> AnyView) {
        let key = tool.rawValue + "|" + Shelf.canonical(url)
        NSApp.activate(ignoringOtherApps: true)  // LSUIElement-App: sonst bleibt das Fenster hinten
        if let w = open[key] {
            w.shelf = shelf
            w.window?.makeKeyAndOrderFront(nil)
            return
        }
        let w = EditWindow(url: url, key: key, shelf: shelf)
        let root: AnyView
        do { root = try content(w) } catch {
            w.releaseAccess()
            return alert("„\(url.lastPathComponent)“: \(error.localizedDescription)")
        }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []  // Größe bestimmt das Fenster, nicht der Inhalt
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = url.lastPathComponent
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)  // über der schwebenden Ablage
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setContentSize(size)
        window.contentMinSize = min
        window.isReleasedWhenClosed = false
        window.delegate = w
        window.center()
        w.window = window
        w.host = host
        open[key] = w
        window.makeKeyAndOrderFront(nil)
    }

    private func deliver(_ outcome: EditMenu.Outcome) {
        ConvertJobs.shared.deliver(outcome, to: ShelfManager.shared.target(for: shelf))
    }

    private func releaseAccess() { if scoped { url.stopAccessingSecurityScopedResource() } }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }

    func windowWillClose(_ notification: Notification) {
        guard Self.open[key] === self else { return }
        Self.open[key] = nil
        // Erst nach dem Schließen abbauen (der Aufruf kann aus der View selbst kommen); die Task hält uns bis dahin.
        Task {
            if let host { Self.dismantle(host) }
            window?.delegate = nil
            window?.contentViewController = nil
            window?.contentView = nil
            host = nil
            window = nil
            shouldClose = { true }
            releaseAccess()
        }
    }

    /// Ersetzt den Inhalt durch nichts: SwiftUI baut die Views ab (`TrimView.dismantleNSView` stoppt den Player).
    static func dismantle(_ host: NSHostingController<AnyView>) {
        host.rootView = AnyView(EmptyView())
        host.view.layoutSubtreeIfNeeded()
    }

    private static func alert(_ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }

    private static func confirmDiscard() -> Bool {
        let a = NSAlert()
        a.messageText = "Änderungen verwerfen?"
        a.informativeText = "Die geänderten Seiten sind noch nicht gespeichert."
        a.addButton(withTitle: "Verwerfen")
        a.addButton(withTitle: "Abbrechen")
        return a.runModal() == .alertFirstButtonReturn
    }
}
