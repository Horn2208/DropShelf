import AppKit

/// Öffnet beim Schütteln einer ziehenden Maus eine Ablage (globaler `.leftMouseDragged`-Monitor).
/// Einstellungen: UserDefaults `shakeEnabled` (Default an), `shakeSensitivity` 0…1 (Default 0,5).
/// Globale Maus-Ereignisse brauchen die Bedienungshilfen-Berechtigung – die Abfrage kommt nur aus den Einstellungen.
@MainActor
final class ShakeDetector {
    static let shared = ShakeDetector()
    static let window: TimeInterval = 0.5       // Richtungswechsel müssen in dieser Zeit passieren
    static let neededReversals = 3

    /// Mindestweg je Richtung in px: Empfindlichkeit 1 → 20 px, 0,5 → 40 px, 0 → 60 px.
    static func minSegment(sensitivity: Double) -> CGFloat { CGFloat(60 - 40 * min(max(sensitivity, 0), 1)) }

    /// Reine Logik: zählt Richtungswechsel in x, wobei jede Richtung ≥ `minSegment` px zurücklegen muss.
    static func reversals(_ xs: [CGFloat], minSegment: CGFloat) -> Int {
        guard var extreme = xs.first else { return 0 }
        var dir = 0  // -1 links, +1 rechts, 0 unbestimmt
        var count = 0
        for x in xs.dropFirst() {
            let d = x - extreme
            if dir == 0 {
                if abs(d) >= minSegment { dir = d > 0 ? 1 : -1; extreme = x }
            } else if (d > 0) == (dir > 0) {
                extreme = x  // Bewegung in gleicher Richtung: Extrem mitziehen
            } else if abs(d) >= minSegment {
                dir = -dir; count += 1; extreme = x
            }
        }
        return count
    }

    private var monitors: [Any] = []
    private var samples: [(x: CGFloat, t: TimeInterval)] = []
    private var downChange = 0
    private var fired = false

    /// Gleicht den Monitor an die Einstellung an (beim Start und bei Änderung des Schalters).
    func sync() {
        let on = UserDefaults.standard.object(forKey: "shakeEnabled") as? Bool ?? true
        if on, monitors.isEmpty {
            monitors = [
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
                    MainActor.assumeIsolated { self?.handle(e) }
                },
                NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
                    MainActor.assumeIsolated { self?.handle(e) }
                    return e
                },
            ].compactMap { $0 }
        } else if !on {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        }
    }

    /// Fragt die Bedienungshilfen-Berechtigung mit dem System-Dialog an.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            samples = []; fired = false
            downChange = NSPasteboard(name: .drag).changeCount
        case .leftMouseUp:
            samples = []; fired = false
        case .leftMouseDragged:
            // Nur wenn der Zug etwas trägt (Drag-Pasteboard hat sich seit mouseDown geändert); ein Schütteln pro Zug.
            guard !fired, NSPasteboard(name: .drag).changeCount != downChange else { return }
            let now = e.timestamp
            samples.append((NSEvent.mouseLocation.x, now))
            samples.removeAll { now - $0.t > Self.window }
            let s = UserDefaults.standard.object(forKey: "shakeSensitivity") as? Double ?? 0.5
            if Self.reversals(samples.map(\.x), minSegment: Self.minSegment(sensitivity: s)) >= Self.neededReversals {
                fired = true; samples = []
                ShelfManager.shared.newShelf(at: NSEvent.mouseLocation)
            }
        default: break
        }
    }

    #if DEBUG
    static func selfCheck() {
        let zig: [CGFloat] = [0, 50, 0, 50, 0, 50]            // 5 Wechsel
        assert(reversals(zig, minSegment: 40) == 4)
        assert(reversals([0, 10, 0, 10, 0, 10], minSegment: 40) == 0)   // zu klein
        assert(reversals([0, 20, 60, 100, 200], minSegment: 40) == 0)   // nur eine Richtung
        assert(reversals([0, 50, 100, 40, 90, 20], minSegment: 40) == 3)
        assert(minSegment(sensitivity: 0.5) == 40)
    }
    #endif
}
