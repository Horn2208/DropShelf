import AppKit
import Carbon

/// Globale Tastenkürzel ⌃⌥A (AirDrop) und ⌃⌥Space (neue Ablage an der Maus) (Carbon, braucht keine Bedienungshilfen-Berechtigung).
/// Je Kürzel per UserDefaults abschaltbar (`hotkeyAirDropEnabled`, `hotkeyShelfEnabled`); `sync()` gleicht an.
@MainActor
final class HotKey {
    static let shared = HotKey()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let keys: [(id: UInt32, code: Int, pref: String)] = [
        (1, kVK_ANSI_A, "hotkeyAirDropEnabled"), (2, kVK_Space, "hotkeyShelfEnabled")]

    func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                Task { @MainActor in
                    if id == 1 { AirDropSender.shared.sendActiveShelf() } else { ShelfManager.shared.newShelf(at: NSEvent.mouseLocation) }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        sync()
    }

    func sync() {
        for k in keys {
            let on = UserDefaults.standard.object(forKey: k.pref) as? Bool ?? true
            if on, refs[k.id] == nil {
                var ref: EventHotKeyRef?
                RegisterEventHotKey(UInt32(k.code), UInt32(controlKey | optionKey),
                                    EventHotKeyID(signature: OSType(0x44534846), id: k.id),
                                    GetApplicationEventTarget(), 0, &ref)
                refs[k.id] = ref
            } else if !on, let ref = refs.removeValue(forKey: k.id) {
                UnregisterEventHotKey(ref)
            }
        }
    }

    func unregister() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
        refs = [:]; handler = nil
    }
}
