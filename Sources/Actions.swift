import AppKit

/// Verfügbare Aktionsknöpfe unter der Ablage. Reihenfolge/Auswahl: `ActionPrefs` (UserDefaults „enabledActions“).
enum ShelfAction: String, CaseIterable, Identifiable {
    case airdrop, message, mail, share, quickLook, reveal, zip, copyPaths
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .airdrop: "dot.radiowaves.up.forward"
        case .message: "message"
        case .mail: "envelope"
        case .share: "square.and.arrow.up"
        case .quickLook: "eye"
        case .reveal: "folder"
        case .zip: "doc.zipper"
        case .copyPaths: "doc.on.doc"
        }
    }
    var title: String {
        switch self {
        case .airdrop: "AirDrop"
        case .message: "Nachrichten"
        case .mail: "Mail"
        case .share: "Teilen…"
        case .quickLook: "Vorschau (Leertaste)"
        case .reveal: "Im Finder zeigen"
        case .zip: "Als ZIP"
        case .copyPaths: "Pfade kopieren"
        }
    }
    var help: String {
        switch self {
        case .airdrop: "Per AirDrop senden (⌃⌥A)"
        case .message: "Per Nachrichten senden"
        case .mail: "Per Mail senden"
        default: title
        }
    }
    private var serviceName: NSSharingService.Name? {
        switch self {
        case .airdrop: .sendViaAirDrop
        case .message: .composeMessage
        case .mail: .composeEmail
        default: nil
        }
    }

    @MainActor func canPerform(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        guard let name = serviceName else { return true }
        return NSSharingService(named: name)?.canPerform(withItems: urls) ?? false
    }

    /// Per Drag auf den Knopf: nur Senden/Teilen (AirDrop, Nachrichten, Mail, Teilen); genau die abgelegten Dateien.
    var acceptsDrop: Bool { self == .airdrop || self == .message || self == .mail || self == .share }

    @MainActor func drop(_ providers: [NSItemProvider], shelf: Shelf, anchor: NSView?) -> Bool {
        guard acceptsDrop, !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers { if let u = await Shelf.resolve(p) { urls.append(u) } }
            guard canPerform(urls) else { return NSSound.beep() }
            run(shelf: shelf, anchor: anchor, urls: urls)
        }
        return true
    }

    /// `dropped`: nur diese Dateien statt der ganzen Ablage.
    @MainActor func run(shelf: Shelf, anchor: NSView?, urls dropped: [URL]? = nil) {
        let all = shelf.items.map(\.url)
        let urls = dropped ?? all
        switch self {
        case .airdrop:
            // „Ablage leeren?“ nur, wenn wirklich die ganze Ablage gesendet wird.
            let whole = Set(urls.map(Shelf.canonical)) == Set(all.map(Shelf.canonical))
            AirDropSender.shared.send(shelf: whole ? shelf : nil, urls: urls)
        case .message, .mail:
            NSApp.activate(ignoringOtherApps: true)  // nonactivating Panel: Teilen-Dialog braucht aktive App
            serviceName.flatMap { NSSharingService(named: $0) }?.perform(withItems: urls)
        case .share:
            NSApp.activate(ignoringOtherApps: true)
            if let anchor { NSSharingServicePicker(items: urls).show(relativeTo: .zero, of: anchor, preferredEdge: .minY) }
        case .quickLook: ((anchor?.window as? ActionsPanel)?.anchorWindow as? ShelfPanel)?.toggleQuickLook()
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .copyPaths:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .zip: Self.zip(urls, into: shelf)
        }
    }

    /// `ditto -c -k --sequesterRsrc --keepParent` in den Caches; das Archiv landet wieder in der Ablage.
    @MainActor private static func zip(_ urls: [URL], into shelf: Shelf) {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        Task.detached {
            let fm = FileManager.default
            let tag = UUID().uuidString.prefix(6)
            let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archiv"
            let out = Shelf.cacheDir.appendingPathComponent("\(name) \(tag).zip")
            var source = urls[0]
            var tmp: URL?
            do {
                try fm.createDirectory(at: Shelf.cacheDir, withIntermediateDirectories: true)
                if urls.count > 1 {  // ditto nimmt eine Quelle: Dateien erst in einen Ordner sammeln
                    let dir = Shelf.cacheDir.appendingPathComponent("tmp \(tag)/Archiv")
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    for u in urls { try fm.copyItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent)) }
                    source = dir; tmp = dir.deletingLastPathComponent()
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, out.path]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                await MainActor.run { shelf.add(out) }
            } catch {
                await MainActor.run { NSSound.beep() }
            }
            if let tmp { try? fm.removeItem(at: tmp) }
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }
}

/// Aktive Aktionen in Reihenfolge, live beobachtbar (Einstellungen ↔ Aktionsleiste).
@MainActor
final class ActionPrefs: ObservableObject {
    static let shared = ActionPrefs()
    static let key = "enabledActions"
    static let maxActive = 5

    @Published var enabled: [ShelfAction] {
        didSet { UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.key) ?? ["airdrop", "message", "share"]
        enabled = raw.compactMap(ShelfAction.init(rawValue:))
    }

    /// Aktive zuerst (in Reihenfolge), danach die übrigen.
    var ordered: [ShelfAction] { enabled + ShelfAction.allCases.filter { !enabled.contains($0) } }
}
