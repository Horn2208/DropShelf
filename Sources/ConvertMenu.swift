import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Klick auf die Dateiendung („.pdf“) öffnet „Umwandeln in …“. Reine Logik (testbar) + Job-Zustand + Views.
enum ConvertMenu {
    struct Preset: Equatable { let id: String; let title: String }

    struct Target: Identifiable, Equatable {
        let type: UTType
        let title: String
        /// Mehr als eins → Untermenü, erster Eintrag = Standard.
        let presets: [Preset]
        /// Vorab-Hinweis (PDF → Text), wird im Menü als Abschnittstitel gezeigt.
        let warning: String?
        /// Gehört zu einem nachladbaren Codec-Paket, das noch nicht installiert ist.
        var pending = false
        var packID: String? = nil
        var id: String { type.identifier }
        var menuTitle: String { pending ? "\(title) (lädt bei Bedarf)" : title }
    }

    /// Ziele aus dem Codec-Manifest: nur gleiche Art wie die Quelle (Bild, Audio, Video), noch nicht vorhandene Typen.
    static func packTargets(from: UTType, manifest: PackManifest, existing: [UTType], installed: (String) -> Bool) -> [Target] {
        let classes: [UTType] = [.image, .audio, .movie]
        return manifest.packs.flatMap { p in
            p.formats.compactMap { ext -> Target? in
                guard let t = UTType(filenameExtension: ext), t != from, !existing.contains(t),
                      classes.contains(where: { from.conforms(to: $0) && t.conforms(to: $0) }) else { return nil }
                return Target(type: t, title: ext.uppercased(), presets: [], warning: nil, pending: !installed(p.id), packID: p.id)
            }
        }
        .sorted { $0.title < $1.title }
    }

    /// Nach (De-)Installation eines Pakets: Menü neu berechnen.
    @MainActor static func resetCache() { cache = [:] }

    /// „PI1_Tut_10.pdf“ → („PI1_Tut_10“, „.pdf“). Versteckte Dateien („.bashrc“) und Namen ohne Endung haben keine.
    static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
        else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    static let presetTitles = ["aac": "AAC", "alac": "ALAC", "heaac": "HE-AAC", "lpcm": "PCM", "opus": "Opus",
                               "vorbis": "Vorbis", "default": "Standard", "prores422": "ProRes 422"]

    /// Menü-Modell aus Zielen und Presets, alphabetisch nach Endung.
    static func targets(from: UTType, to targets: [UTType], presets: (UTType) -> [String]) -> [Target] {
        targets.map { t in
            Target(type: t, title: (t.preferredFilenameExtension ?? t.identifier).uppercased(),
                   presets: presets(t).map { Preset(id: $0, title: presetTitles[$0] ?? $0.uppercased()) },
                   warning: from == .pdf && PDFConverter.writableText.contains(t) ? PDFConverter.textExtractionWarning : nil)
        }
        .sorted { $0.title < $1.title }
    }

    struct MenuSection: Identifiable { let title: String; let targets: [Target]; let warned: Bool; var id: String { title } }

    /// Menü-Abschnitte (Endungs- und Rechtsklick-Menü): normale Ziele unter „Umwandeln in“, Ziele mit Hinweis unter dem Hinweis.
    static func sections(_ ts: [Target]) -> [MenuSection] {
        let plain = ts.filter { $0.warning == nil }
        let warned = ts.filter { $0.warning != nil }
        var r: [MenuSection] = []
        if !plain.isEmpty { r.append(MenuSection(title: "Umwandeln in", targets: plain, warned: false)) }
        if let w = warned.first?.warning { r.append(MenuSection(title: w, targets: warned, warned: true)) }
        return r
    }

    /// Rechtsklick-Untermenü „Umwandeln in“ mit denselben Zielen, Presets und Jobs wie das Endungs-Menü; ohne Ziele nil.
    @MainActor static func menuItem(for url: URL, shelf: Shelf) -> NSMenuItem? {
        let ts = targets(for: url)
        guard !ts.isEmpty else { return nil }
        let sub = NSMenu()
        for s in sections(ts) {
            if s.warned {
                if !sub.items.isEmpty { sub.addItem(.separator()) }
                sub.addItem(.sectionHeader(title: s.title))
            }
            for t in s.targets {
                if t.presets.count > 1 {
                    let i = NSMenuItem(title: t.menuTitle, action: nil, keyEquivalent: "")
                    i.submenu = NSMenu()
                    for p in t.presets {
                        i.submenu?.addItem(ActionMenuItem(p.title) { ConvertJobs.shared.start(url, t, preset: p.id, shelf: shelf) })
                    }
                    sub.addItem(i)
                } else {
                    sub.addItem(ActionMenuItem(t.menuTitle) { ConvertJobs.shared.start(url, t, preset: t.presets.first?.id, shelf: shelf) })
                }
            }
        }
        let item = NSMenuItem(title: "Umwandeln in", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @MainActor private static var cache: [String: [Target]] = [:]

    /// Ziele für eine Datei (Typ wie in `ConverterRegistry.convert`: Inhaltstyp, sonst Endung). Je Endung gecacht.
    @MainActor static func targets(for url: URL) -> [Target] {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return [] }
        if let c = cache[ext] { return c }
        let candidates = [(try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType, UTType(filenameExtension: ext)]
        var result: [Target] = []
        defer { cache[ext] = result }
        for case let from? in candidates {
            let to = ConverterRegistry.targets(for: from)
            guard !to.isEmpty else { continue }
            result = targets(from: from, to: to) { t in
                switch ConverterRegistry.converter(for: Conversion(from: from, to: t))?.id {
                case "audio": return AudioConverter.availablePresets(for: t)
                case "video": return VideoConverter.availablePresets(for: t)
                default: return []
                }
            }
            break
        }
        if let from = candidates.compactMap({ $0 }).first {
            result += packTargets(from: from, manifest: ConverterRegistry.packManifest, existing: result.map(\.type)) {
                PackRegistry.isInstalled($0)
            }
        }
        return result
    }
}

/// Ob ein Umwandeln-Ergebnis den Ablage-Eintrag ersetzt oder hinzukommt (Einstellungen + Dialogantwort). Reine Logik, testbar.
enum ConvertPrefs {
    enum Placement { case replace, add }
    enum Answer { case replace, add, cancel }
    static let replaceKey = "convertReplacesItem"  // Standard an
    static let askKey = "convertAsk"               // Standard an

    /// nil = vorher fragen.
    static func preset(_ d: UserDefaults) -> Placement? {
        guard !(d.object(forKey: askKey) as? Bool ?? true) else { return nil }
        return d.object(forKey: replaceKey) as? Bool ?? true ? .replace : .add
    }

    /// Dialogantwort → Platzierung (nil = abbrechen). „Nicht mehr fragen“ speichert die Wahl und schaltet die Nachfrage ab.
    static func resolve(_ a: Answer, suppress: Bool, _ d: UserDefaults) -> Placement? {
        let p: Placement
        switch a {
        case .replace: p = .replace
        case .add: p = .add
        case .cancel: return nil
        }
        if suppress {
            d.set(p == .replace, forKey: replaceKey)
            d.set(false, forKey: askKey)
        }
        return p
    }
}

/// NSMenuItem mit Closure statt Target/Selector.
@MainActor final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void
    init(_ title: String, _ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    @objc private func run() { handler() }
}

/// Laufende Umwandlungen (Beschäftigt-Zustand je Datei) und eine kurze Meldung je Ablage.
@MainActor final class ConvertJobs: ObservableObject {
    static let shared = ConvertJobs()

    struct Banner: Identifiable {
        let id = UUID()
        let text: String
        /// Gesetzt bei Cache-Rückfall: „Ordner freigeben…“ für den Ordner dieser Datei.
        let folderFor: URL?
        /// Nach erfolgreicher Freigabe erneut versuchen (Umbenennen ohne Schreibrecht).
        var retry: (@MainActor () -> Void)? = nil
    }

    @Published private(set) var busy = Set<URL>()
    @Published private(set) var banners: [UUID: Banner] = [:]

    func start(_ url: URL, _ target: ConvertMenu.Target, preset: String?, shelf: Shelf) {
        guard busy.insert(url).inserted else { return }
        let shelfID = shelf.id
        let to = target.type
        Task {
            defer { busy.remove(url) }
            let reencode = to == .quickTimeMovie || to == .mpeg4Movie
                ? await VideoConverter.willReencode(url, to: to, preset: preset) : false
            let hint = reencode ? "Das Video passt nicht unverändert in \(target.title). Das Umwandeln kann dauern." : nil
            var placement = ConvertPrefs.preset(.standard)
            if placement == nil {
                // Ein Dialog: Ersetzen / Hinzufügen, ggf. mit dem Neukodierungs-Hinweis.
                let a = NSAlert()
                a.messageText = "„\(url.lastPathComponent)“ in \(target.title) umwandeln?"
                a.informativeText = (hint.map { $0 + "\n\n" } ?? "")
                    + "„Ersetzen“ tauscht nur den Eintrag in der Ablage aus, die Originaldatei bleibt unverändert."
                a.addButton(withTitle: "Ersetzen")
                a.addButton(withTitle: "Als neue Datei hinzufügen")
                a.addButton(withTitle: "Abbrechen")
                a.showsSuppressionButton = true
                a.suppressionButton?.title = "Nicht mehr fragen"
                let answer: ConvertPrefs.Answer = switch a.runModal() {
                case .alertFirstButtonReturn: .replace
                case .alertSecondButtonReturn: .add
                default: .cancel
                }
                placement = ConvertPrefs.resolve(answer, suppress: a.suppressionButton?.state == .on, .standard)
            } else if let hint {
                let a = NSAlert()
                a.messageText = "Video wird neu kodiert"
                a.informativeText = hint
                a.addButton(withTitle: "Umwandeln")
                a.addButton(withTitle: "Abbrechen")
                if a.runModal() != .alertFirstButtonReturn { placement = nil }
            }
            guard let placement else { return }
            do {
                let o = ConvertOptions(preset: preset)
                // Ersetzen: Ergebnis nur im Cache, das Original und sein Ordner bleiben unberührt.
                let mode: OutputMode = placement == .replace ? .cache : .besideOriginal
                let p = try await Task.detached { try await ConverterRegistry.convertReporting(url, to: to, o, mode: mode) }.value
                if placement == .replace {
                    shelf.replaceURLs([url: p.url])  // gleiche ID → Position und Auswahl bleiben; alte Datei wird nicht gelöscht
                } else {
                    shelf.add(p.url)
                }
                if let n = p.notice { show(Banner(text: n, folderFor: url), on: shelfID) }
            } catch ConvertError.codecMissing(let packID) {
                await offerCodec(packID, then: { self.start(url, target, preset: preset, shelf: shelf) }, on: shelfID)
            } catch {
                show(Banner(text: "Umwandeln fehlgeschlagen: \(error.localizedDescription)", folderFor: nil), on: shelfID)
            }
        }
    }

    /// Alert „Codec laden?“; bei „Laden“ Fortschritt im Banner, danach einmalig neu starten.
    private func offerCodec(_ packID: String, then retry: @escaping @MainActor () -> Void, on shelfID: UUID) async {
        guard let pack = ConverterRegistry.packManifest.packs.first(where: { $0.id == packID }) else {
            return show(Banner(text: "Codec „\(packID)“ ist nicht verfügbar.", folderFor: nil), on: shelfID)
        }
        let a = NSAlert()
        a.messageText = "Codec laden?"
        a.informativeText = "Für diese Umwandlung wird einmalig der Codec „\(pack.id)“ (\(pack.formats.map { $0.uppercased() }.joined(separator: ", "))) heruntergeladen."
        a.addButton(withTitle: "Laden")
        a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await PackInstall.run(pack) { p in
                Task { @MainActor in self.show(Banner(text: "Codec wird geladen … \(Int(p * 100)) %", folderFor: nil), on: shelfID) }
            }
            dismiss(shelfID)
            retry()
        } catch {
            show(Banner(text: "Codec laden fehlgeschlagen: \(error.localizedDescription)", folderFor: nil), on: shelfID)
        }
    }

    /// Auftrag außerhalb des Umwandelns (Menü „Bearbeiten“): `urls` sind währenddessen beschäftigt (Spinner,
    /// kein Doppelstart), `work` läuft im Hintergrund, Ergebnisse kommen in die Ablage.
    /// false: eine der Dateien ist schon beschäftigt, nichts gestartet.
    @discardableResult
    func run(_ urls: [URL], shelf: Shelf, failure: String, _ work: @escaping @Sendable () async throws -> EditMenu.Outcome) -> Bool {
        guard busy.isDisjoint(with: urls) else { return false }
        busy.formUnion(urls)
        let shelfID = shelf.id
        Task {
            defer { busy.subtract(urls) }
            do {
                deliver(try await Task.detached { try await work() }.value, to: shelf)
            } catch {
                show(Banner(text: "\(failure): \(error.localizedDescription)", folderFor: nil), on: shelfID)
            }
        }
        return true
    }

    /// Ergebnis in die Ablage legen und ggf. melden.
    func deliver(_ o: EditMenu.Outcome, to shelf: Shelf) {
        o.add.forEach { shelf.add($0) }
        if let n = o.notice { show(Banner(text: n, folderFor: o.folderFor), on: shelf.id) }
    }

    func dismiss(_ shelfID: UUID) { banners[shelfID] = nil }

    func grantAccess(_ b: Banner, on shelfID: UUID) {
        dismiss(shelfID)
        guard let url = b.folderFor else { return }
        NSApp.activate()
        Task { if await FolderAccessStore.shared.requestAccess(for: url) != nil { b.retry?() } }
    }

    /// Umbenennen aus dem Namensfeld (Endung bleibt). Ungültig oder fehlgeschlagen → Meldung, Name bleibt;
    /// ohne Schreibrecht mit „Ordner freigeben…“ und danach neuem Versuch.
    func rename(_ url: URL, to newBase: String, shelf: Shelf) {
        let dir = url.deletingLastPathComponent()
        let step = Organize.renameStep(url.lastPathComponent, newBase: newBase) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        if let p = step.problem { return show(Banner(text: p, folderFor: nil), on: shelf.id) }
        guard step.new != step.old else { return }
        do {
            try Organize.renameItems([step], in: dir, shelf: shelf)
        } catch {
            var b = Banner(text: error.localizedDescription, folderFor: nil)
            if case .noWriteAccess? = error as? RenameError {
                b = Banner(text: b.text, folderFor: url, retry: { [weak self] in self?.rename(url, to: newBase, shelf: shelf) })
            }
            show(b, on: shelf.id)
        }
    }

    private func show(_ b: Banner, on shelfID: UUID) {
        banners[shelfID] = b
        Task {
            try? await Task.sleep(for: .seconds(b.folderFor == nil ? 6 : 12))
            if banners[shelfID]?.id == b.id { banners[shelfID] = nil }
        }
    }
}

/// Die Endung als klickbarer Teil des Namens (ohne Kapsel, beim Überfahren dezent hinterlegt). Ohne mögliche Ziele nur Text.
struct ExtensionMenu: View {
    let url: URL
    let shelf: Shelf
    var size: CGFloat = 12
    var selected = false
    @ObservedObject private var jobs = ConvertJobs.shared
    @State private var hover = false

    var body: some View {
        let ext = ConvertMenu.split(url.lastPathComponent).ext
        let targets = ext.isEmpty ? [] : ConvertMenu.targets(for: url)
        let text = Text(ext).font(.system(size: size, weight: .medium)).lineLimit(1)
            .foregroundStyle(selected ? Color.white : Color.primary)
        if jobs.busy.contains(url) {
            HStack(spacing: 3) { text.opacity(0.6); ProgressView().controlSize(.mini) }
                .help("Wird bearbeitet …")
        } else if targets.isEmpty {
            text
        } else {
            Menu { items(targets) } label: {
                // Hinterlegung nur außen (negatives Padding), damit Name und Endung lückenlos aneinanderstehen.
                text.background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill((selected ? Color.white : Color.primary).opacity(hover ? 0.2 : 0)).padding(-2))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .onHover { hover = $0 }
            .animation(Motion.snappy, value: hover)
            .help("Umwandeln in …")
        }
    }

    @ViewBuilder private func items(_ ts: [ConvertMenu.Target]) -> some View {
        ForEach(ConvertMenu.sections(ts)) { s in Section(s.title) { ForEach(s.targets) { item($0) } } }
    }

    @ViewBuilder private func item(_ t: ConvertMenu.Target) -> some View {
        if t.presets.count > 1 {
            Menu(t.title) {
                ForEach(t.presets, id: \.id) { p in
                    Button(p.title) { ConvertJobs.shared.start(url, t, preset: p.id, shelf: shelf) }
                }
            }
        } else {
            Button(t.title) { ConvertJobs.shared.start(url, t, preset: t.presets.first?.id, shelf: shelf) }
        }
    }
}

/// Kurze Meldung unten in der Ablage (Fehler oder Cache-Rückfall mit „Ordner freigeben…“).
struct ConvertBanner: View {
    let shelf: Shelf
    @ObservedObject private var jobs = ConvertJobs.shared

    var body: some View {
        let b = jobs.banners[shelf.id]
        VStack {
            if let b {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(b.text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { jobs.dismiss(shelf.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain).help("Schließen")
                    }
                    if b.folderFor != nil {
                        Button("Ordner freigeben…") { jobs.grantAccess(b, on: shelf.id) }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .glassBG(RoundedRectangle(cornerRadius: 12, style: .continuous), line: 0.5)
                .padding(8)
                .transition(.opacity)
            }
        }
        .animation(Motion.smooth, value: b?.id)
    }
}

/// Dateiname mit Endung als zusammenhängender Text. Klick auf den Namen macht ihn bearbeitbar (vorbelegt, markiert);
/// Enter oder Fokusverlust bestätigt, Esc bricht ab. Klick auf die Endung öffnet „Umwandeln in …“.
/// `selected`: Finder-Markierung als eine blaue Pille um Name und Endung. `onTap` läuft vor dem Bearbeiten (z. B. Datei auswählen).
struct NameField: View {
    let url: URL
    let shelf: Shelf
    var size: CGFloat = 12
    var selected = false
    var lines = 1
    var onTap: () -> Void = {}
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let base = ConvertMenu.split(url.lastPathComponent).base
        let pill = selected && !editing
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            name(base)
            ExtensionMenu(url: url, shelf: shelf, size: size, selected: pill).layoutPriority(1)
        }
        .padding(.horizontal, pill ? 4 : 0).padding(.vertical, pill ? 1 : 0)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(pill ? Color.accentColor : .clear))
    }

    @ViewBuilder private func name(_ base: String) -> some View {
        let font = Font.system(size: size, weight: .medium)
        if editing {
            TextField("", text: $text)
                .textFieldStyle(.plain).font(font)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, f in if !f { commit() } }
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.12)))
                .frame(minWidth: 60)
                .onAppear {
                    text = base
                    ShelfPanel.focus(shelf)  // Panel muss Schlüsselfenster sein, sonst kommen keine Tasten an
                    DispatchQueue.main.async { focused = true }
                }
        } else {
            Text(base).font(font)
                .lineLimit(lines).truncationMode(.middle)
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Rectangle())
                .onTapGesture { onTap(); editing = true }
                .help("Klicken zum Umbenennen")
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        ConvertJobs.shared.rename(url, to: text, shelf: shelf)
    }
}
