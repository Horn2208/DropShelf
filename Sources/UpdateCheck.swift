import AppKit
import Foundation
#if SPARKLE
import Sparkle
#endif

/// Reine Logik rund um Updates (kein Netz, keine UI).
enum UpdateCheck {
    /// Release-Seite für Builds ohne Sparkle (Troll-Varianten, Tests).
    static let releasesPage = URL(string: "https://github.com/Horn2208/DropShelf/releases/latest")!

    /// Alter Schalter aus der Zeit vor Sparkle; wird einmalig übernommen.
    static let legacyAutoKey = "updateCheckEnabled"

    /// true, wenn `key` ein gültiger EdDSA-Public-Key ist (Base64, 32 Byte).
    /// Ohne gültigen Schlüssel wird Sparkle nicht gestartet, damit kein Fehlerdialog beim Start erscheint.
    static func isValidPublicKey(_ key: String?) -> Bool {
        guard let key, let d = Data(base64Encoded: key.trimmingCharacters(in: .whitespaces)) else { return false }
        return d.count == 32
    }

    /// Übernimmt den alten Schalter: nur ein ausdrückliches „aus“ wird weitergegeben, sonst nil (Sparkle-Standard gilt).
    static func migratedAutomaticChecks(legacy: Any?) -> Bool? {
        (legacy as? Bool) == false ? false : nil
    }
}

/// Zustand für Menü und Einstellungen. In der Haupt-App steuert Sparkle Prüfung, Download und Installation.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var canCheck = false
    @Published private(set) var message: String?

    #if SPARKLE
    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?
    private let started: Bool

    private init() {
        let ok = UpdateCheck.isValidPublicKey(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        started = ok
        controller = SPUStandardUpdaterController(startingUpdater: ok, updaterDelegate: nil, userDriverDelegate: nil)
        guard ok else {
            message = "Updates sind in diesem Build nicht eingerichtet (SUPublicEDKey fehlt)."
            return
        }
        let d = UserDefaults.standard
        if let v = UpdateCheck.migratedAutomaticChecks(legacy: d.object(forKey: UpdateCheck.legacyAutoKey)) {
            controller.updater.automaticallyChecksForUpdates = v
        }
        d.removeObject(forKey: UpdateCheck.legacyAutoKey)
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { @Sendable u, _ in
            let v = u.canCheckForUpdates
            Task { @MainActor in UpdateManager.shared.canCheck = v }
        }
    }

    /// Automatische Prüfung (Sparkle speichert den Wert selbst).
    var automaticChecks: Bool {
        get { started && controller.updater.automaticallyChecksForUpdates }
        set {
            guard started else { return }
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticChecksAvailable: Bool { started }

    /// Sparkle zeigt Fortschritt und Versionshinweise und installiert nach Bestätigung.
    func checkForUpdates() {
        guard started else { return }
        controller.checkForUpdates(nil)
    }
    #else
    private init() { canCheck = true }

    var automaticChecks: Bool {
        get { false }
        set {}
    }

    var automaticChecksAvailable: Bool { false }

    /// Ohne Sparkle: Release-Seite öffnen.
    func checkForUpdates() { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
    #endif

    /// Beim Start aufrufen: der Zugriff auf `shared` legt den Updater an, Sparkle übernimmt dann den Zeitplan.
    func start() {}
}
