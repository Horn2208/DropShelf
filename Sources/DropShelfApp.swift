import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FunEffects.registerDefaults()
        UpdateManager.shared.start()
        #if DEBUG
        ShelfRecord.selfCheck()
        ShakeDetector.selfCheck()
        BackdropPatch.selfCheck()
        ClipboardStore.selfCheck()
        Task {  // Drop-Auflösung: Datei bleibt Datei, Text wird Cache-Datei
            let f = URL(fileURLWithPath: "/etc/hosts")
            let a = await Shelf.resolve(NSItemProvider(object: f as NSURL))
            let b = await Shelf.resolve(NSItemProvider(object: "hallo" as NSString))
            assert(a?.path == f.path, "resolve file")
            assert(b.map(Shelf.isCacheFile) == true && (try? String(contentsOf: b!)) == "hallo", "resolve text")
            b.map { try? FileManager.default.removeItem(at: $0) }
            NSLog("DROP-SELFCHECK ok %@ %@", a?.path ?? "nil", b?.lastPathComponent ?? "nil")
        }
        #endif
        ShelfManager.shared.restore()
        if ShelfManager.shared.isEmpty && UserDefaults.standard.object(forKey: "openShelfOnLaunch") as? Bool ?? true {
            ShelfManager.shared.newShelf()
        }
        HotKey.shared.register()
        ShakeDetector.shared.sync()
        ClipboardStore.shared.sync()
        #if DEBUG
        debugLaunchArgs()
        #endif
        launched = true
        WelcomeWindow.showIfNeeded()
        if !pendingOpen.isEmpty { addToShelf(pendingOpen); pendingOpen = [] }
    }

    private var launched = false
    private var pendingOpen: [URL] = []  // Kaltstart: `open` kann vor restore() eintreffen; erst danach einsortieren

    /// Dateien von außen (Finder-Menü, `open -b`): in die aktive Ablage, sonst in eine neue.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if launched { addToShelf(files) } else { pendingOpen += files }
    }

    private func addToShelf(_ files: [URL]) {
        guard !files.isEmpty else { return }
        if ShelfManager.shared.activeShelf == nil { ShelfManager.shared.newShelf() }
        files.forEach { ShelfManager.shared.activeShelf?.add($0) }
    }

    #if DEBUG
    /// Nur Debug: `-DebugSeed a:b` legt Dateien in eine Ablage, `-DebugDetail YES` öffnet die Detail-Ansicht,
    /// `-DebugOpenSettings YES` (mit `-settingsTab perms`) öffnet die Einstellungen.
    private func debugLaunchArgs() {
        let d = UserDefaults.standard
        if let seed = d.string(forKey: "DebugSeed") {
            ShelfManager.shared.newShelf()
            let shelf = ShelfManager.shared.activeShelf
            seed.split(separator: ":").forEach { shelf?.add(URL(fileURLWithPath: String($0))) }
            if d.bool(forKey: "DebugDetail") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { shelf?.expanded = true } }
            // `-DebugExpandLoop N`: N-mal auf-/zuklappen und Bildraten der Übergänge loggen (EXPAND-FRAMES).
            let loops = d.integer(forKey: "DebugExpandLoop")
            if loops > 0, #available(macOS 14, *), let shelf {
                for i in 0..<loops {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 1.0) {
                        guard let view = NSApp.windows.first(where: { ($0 as? ShelfPanel)?.shelf === shelf })?.contentView else { return }
                        FrameMeter.measure(view, seconds: 0.45, tag: shelf.expanded ? "collapse" : "expand")
                        shelf.expanded.toggle()
                    }
                }
            }
        }
        if d.bool(forKey: "DebugOpenHistory") {
            if HistoryStore.shared.entries.isEmpty {
                let png = NSImage(size: NSSize(width: 80, height: 60), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
                    .tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                for names in [["Notizen"], ["Foto", "Bericht", "Skizze"], ["Rechnung"]] {
                    let items = names.compactMap { n in
                        Shelf.cacheFile(n, n == "Foto" ? "png" : "txt", n == "Foto" ? png ?? Data() : Data(n.utf8))
                    }.map { u in Shelf.Item(url: u, bookmark: try? u.bookmarkData(options: .withSecurityScope)) }
                    HistoryStore.shared.add(items)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { HistoryPanel.toggle() }
        }
        if d.bool(forKey: "DebugOpenSettings") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { SettingsOpener.open() } }
    }
    #endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ShelfManager.shared.newShelf()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShelfManager.shared.save()
        ShelfManager.shared.purgeOrphans()
        HotKey.shared.unregister()
        ClipboardStore.shared.flush()
    }
}

@main
struct DropShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var hotkeys = HotKey.shared
    @ObservedObject private var updates = UpdateManager.shared

    private static let dates: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de")
        f.doesRelativeDateFormatting = true  // „Heute, 16:31“
        f.dateStyle = .short; f.timeStyle = .short
        return f
    }()

    var body: some Scene {
        MenuBarExtra("DropShelf", systemImage: "tray.and.arrow.down") {
            let _ = hotkeys.revision  // Kürzel-Anzeige neu aufbauen, wenn sich ein Kürzel ändert
            hotkeyButton("Neue Ablage", 2) { ShelfManager.shared.newShelf(at: NSEvent.mouseLocation) }
            hotkeyButton("Ablage aus der Zwischenablage", 4) { ShelfManager.shared.newShelfFromClipboard() }
            hotkeyButton("Zwischenablage-Verlauf…", 5) { ClipboardPanel.toggle() }
            if HistoryStore.enabled, !history.entries.isEmpty {
                Section("Vorherige Ablagen") {
                    ForEach(history.entries.prefix(3)) { e in
                        Button { HistoryPanel.restore(e) } label: {
                            Text("\(e.title) — \(Self.dates.string(from: e.date))")
                            Image(nsImage: Self.icon(e))
                        }
                    }
                }
                Button("Alle Ablagen…") { HistoryPanel.toggle() }
            }
            Divider()
            Button("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")") {}.disabled(true)
            Button("Nach Updates suchen…") { updates.checkForUpdates() }.disabled(!updates.canCheck)
            Button("Über DropShelf…") { UserDefaults.standard.set(SettingsSection.about.rawValue, forKey: "settingsTab"); SettingsOpener.open() }
            Button("Einstellungen…") { SettingsOpener.open() }.keyboardShortcut(",")
            Divider()
            Button("DropShelf beenden") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }

    /// Menüeintrag mit dem aktuell aufgenommenen Kürzel (nur zur Anzeige; ausgelöst wird es global über Carbon).
    @ViewBuilder
    private func hotkeyButton(_ title: String, _ id: UInt32, _ action: @escaping () -> Void) -> some View {
        let on = UserDefaults.standard.object(forKey: ["hotkeyAirDropEnabled", "hotkeyShelfEnabled", "hotkeyHistoryEnabled", "hotkeyClipboardEnabled", "hotkeyClipHistoryEnabled", "hotkeyFinderEnabled"][Int(id) - 1]) as? Bool ?? true
        if on, let k = HotKey.menuShortcut(id) {
            Button(title, action: action).keyboardShortcut(k.key, modifiers: k.mods)
        } else {
            Button(title, action: action)
        }
    }

    private static func icon(_ e: HistoryStore.Entry) -> NSImage {
        let img = (e.urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()).copy() as! NSImage
        img.size = NSSize(width: 18, height: 18)
        return img
    }
}

#if DEBUG
/// Nur Debug: zählt Bilder per Display-Link während eines Übergangs; „late“ = Abstand > 1,5 Bildzeiten (Hänger).
@available(macOS 14, *)
@MainActor
final class FrameMeter: NSObject {
    private var stamps: [CFTimeInterval] = []
    private var frame: CFTimeInterval = 0
    private var link: CADisplayLink?
    private let tag: String
    private let start = CACurrentMediaTime()

    private init(tag: String) { self.tag = tag }

    static func measure(_ view: NSView, seconds: Double, tag: String) {
        let m = FrameMeter(tag: tag)
        m.link = view.displayLink(target: m, selector: #selector(tick(_:)))
        m.link?.add(to: .main, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { m.finish() }
    }

    @objc private func tick(_ l: CADisplayLink) { stamps.append(l.timestamp); frame = l.targetTimestamp - l.timestamp }

    private func finish() {
        link?.invalidate()
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let first = (stamps.first ?? start) - start
        NSLog("EXPAND-FRAMES %@ frames=%d hz=%.0f firstFrameAfter=%.1fms maxGap=%.1fms late=%d", tag, stamps.count,
              frame > 0 ? 1 / frame : 0, first * 1000, (gaps.max() ?? 0) * 1000, gaps.filter { $0 > frame * 1.5 }.count)
    }
}
#endif
