import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ShelfRecord.selfCheck()
        ShakeDetector.selfCheck()
        #endif
        ShelfManager.shared.restore()
        if ShelfManager.shared.isEmpty && UserDefaults.standard.object(forKey: "openShelfOnLaunch") as? Bool ?? true {
            ShelfManager.shared.newShelf()
        }
        HotKey.shared.register()
        ShakeDetector.shared.sync()
        #if DEBUG
        debugLaunchArgs()
        #endif
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
    }
}

@main
struct DropShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var hotkeys = HotKey.shared

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
        let on = UserDefaults.standard.object(forKey: ["hotkeyAirDropEnabled", "hotkeyShelfEnabled", "hotkeyHistoryEnabled", "hotkeyClipboardEnabled"][Int(id) - 1]) as? Bool ?? true
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
