import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ShelfRecord.selfCheck()
        #endif
        ShelfManager.shared.restore()
    }

    func applicationWillTerminate(_ notification: Notification) { ShelfManager.shared.save() }
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
