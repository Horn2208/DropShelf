import AppKit
import Carbon
import SwiftUI

/// Globale Tastenkürzel ⌃⌥A (AirDrop), ⌃⌥Space (neue Ablage an der Maus), ⌃⌥V (Verlauf) und ⌃⌥C (Ablage aus der Zwischenablage) (Carbon, braucht keine Bedienungshilfen-Berechtigung).
/// Kürzel frei belegbar (Einstellungen › Kürzel). Je Kürzel per UserDefaults abschaltbar (`hotkeyAirDropEnabled`, `hotkeyShelfEnabled`, `hotkeyHistoryEnabled`); `sync()` gleicht an.
@MainActor
final class HotKey: ObservableObject {
    @Published private(set) var revision = 0  // zählt bei jeder Änderung hoch: das Menü zeigt immer die aktuellen Kürzel
    static let shared = HotKey()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let keys: [(id: UInt32, code: Int, pref: String)] = [
        (1, kVK_ANSI_A, "hotkeyAirDropEnabled"), (2, kVK_Space, "hotkeyShelfEnabled"), (3, kVK_ANSI_V, "hotkeyHistoryEnabled"),
        (4, kVK_ANSI_C, "hotkeyClipboardEnabled")]

    /// Gespeichertes Kürzel (`hotkeyCode<id>`/`hotkeyMods<id>`, Carbon-Modifier) oder Standard (⌃⌥ + Taste).
    static func defaultCombo(_ id: UInt32) -> (code: Int, mods: Int) {
        ([1: kVK_ANSI_A, 2: kVK_Space, 3: kVK_ANSI_V, 4: kVK_ANSI_C][Int(id)] ?? 0, controlKey | optionKey)
    }

    static func combo(_ id: UInt32) -> (code: Int, mods: Int) {
        let d = UserDefaults.standard
        guard d.object(forKey: "hotkeyCode\(id)") != nil else { return defaultCombo(id) }
        return (d.integer(forKey: "hotkeyCode\(id)"), d.integer(forKey: "hotkeyMods\(id)"))
    }

    /// Anzeige im Menü: Taste + Modifier des aktuellen Kürzels (nil bei Tasten ohne Zeichen).
    static func menuShortcut(_ id: UInt32) -> (key: KeyEquivalent, mods: SwiftUI.EventModifiers)? {
        let c = combo(id)
        let name = ShortcutRecorder.keyName(c.code)
        let key: KeyEquivalent
        switch name {
        case "Space": key = .space
        case "↩": key = .return
        case "←": key = .leftArrow
        case "→": key = .rightArrow
        case "↑": key = .upArrow
        case "↓": key = .downArrow
        default:
            guard name.count == 1, let ch = name.lowercased().first else { return nil }
            key = KeyEquivalent(ch)
        }
        var m: SwiftUI.EventModifiers = []
        if c.mods & controlKey != 0 { m.insert(.control) }
        if c.mods & optionKey != 0 { m.insert(.option) }
        if c.mods & shiftKey != 0 { m.insert(.shift) }
        if c.mods & cmdKey != 0 { m.insert(.command) }
        return (key, m)
    }

    func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                Task { @MainActor in
                    switch id {
                    case 1: AirDropSender.shared.sendActiveShelf()
                    case 2: ShelfManager.shared.newShelf(at: NSEvent.mouseLocation)
                    case 3: HistoryPanel.toggle()
                    default: ShelfManager.shared.newShelfFromClipboard()
                    }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        sync()
    }

    func sync() {
        refs.values.forEach { UnregisterEventHotKey($0) }  // erst alte freigeben, dann neu (Kürzel können sich geändert haben)
        refs = [:]
        revision += 1
        for k in keys where UserDefaults.standard.object(forKey: k.pref) as? Bool ?? true {
            let c = Self.combo(k.id)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(c.code), UInt32(c.mods), EventHotKeyID(signature: OSType(0x44534846), id: k.id),
                                GetApplicationEventTarget(), 0, &ref)
            refs[k.id] = ref
        }
    }

    func unregister() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
        refs = [:]; handler = nil
    }
}
