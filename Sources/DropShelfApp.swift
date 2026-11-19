import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ShelfRecord.selfCheck()
        #endif
        ShelfManager.shared.restore()
        if ShelfManager.shared.isEmpty && UserDefaults.standard.object(forKey: "openShelfOnLaunch") as? Bool ?? true {
            ShelfManager.shared.newShelf()
        }
        HotKey.shared.register()
    }

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
            Divider()
            Button("Beenden") { NSApplication.shared.terminate(nil) }
        }
    }
}
