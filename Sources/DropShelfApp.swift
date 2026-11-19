import SwiftUI

@main
struct DropShelfApp: App {
    var body: some Scene {
        MenuBarExtra("DropShelf", systemImage: "tray.and.arrow.down") {
            Button("Neue Ablage") { print("Neue Ablage") }  // Platzhalter bis Phase 2
            Divider()
            Button("Beenden") { NSApplication.shared.terminate(nil) }
        }
    }
}
