import AppKit

/// Sendet Dateien per AirDrop und hält Security-Scope + Service bis zum Ende der Übertragung.
@MainActor
final class AirDropSender: NSObject, NSSharingServiceDelegate {
    static let shared = AirDropSender()
    private var service: NSSharingService?
    private var scoped: [URL] = []
    private weak var shelf: Shelf?

    static func unavailableReason(for urls: [URL]) -> String? {
        if urls.isEmpty { return "Ablage ist leer" }
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            return "AirDrop nicht verfügbar – WLAN/Bluetooth an?"
        }
        return nil
    }

    func sendActiveShelf() {
        guard let shelf = ShelfManager.shared.activeShelf else { return }
        send(shelf: shelf, urls: shelf.items.map(\.url))
    }

    func send(shelf: Shelf, urls: [URL]) {
        guard service == nil,  // läuft schon eine Übertragung
              Self.unavailableReason(for: urls) == nil,
              let s = NSSharingService(named: .sendViaAirDrop) else { NSSound.beep(); return }
        s.delegate = self
        service = s
        self.shelf = shelf
        scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        NSApp.activate(ignoringOtherApps: true)  // nonactivating Panel: Teilen-Dialog braucht aktive App
        s.perform(withItems: urls)
    }

    private func finish() {
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
        scoped = []
        service = nil
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let shelf = shelf
        finish()
        guard UserDefaults.standard.object(forKey: "askClearAfterAirDrop") as? Bool ?? true, let shelf else { return }
        let a = NSAlert()
        a.messageText = "Ablage leeren?"
        a.addButton(withTitle: "Leeren")
        a.addButton(withTitle: "Behalten")
        if a.runModal() == .alertFirstButtonReturn { shelf.remove(shelf.items.map(\.url)) }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish()
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError { return }
        let a = NSAlert()
        a.messageText = "AirDrop fehlgeschlagen"
        a.informativeText = error.localizedDescription
        a.runModal()
    }
}
