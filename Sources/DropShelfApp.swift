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

    var body: some Scene {
        MenuBarExtra("DropShelf", systemImage: "tray.and.arrow.down") {
            Button("Neue Ablage") { ShelfManager.shared.newShelf() }
            Button("Verlauf…") { HistoryPanel.toggle() }
            Button("Einstellungen…") { SettingsOpener.open() }.keyboardShortcut(",")
            Divider()
            Button("Beenden") { NSApplication.shared.terminate(nil) }
        }
    }
}
