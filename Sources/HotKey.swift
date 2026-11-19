import AppKit
import Carbon

/// Globales Tastenkürzel ⌃⌥A (AirDrop) und ⌃⌥Space (neue Ablage an der Maus) (Carbon, braucht keine Bedienungshilfen-Berechtigung).
@MainActor
final class HotKey {
    static let shared = HotKey()
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func register() {
        guard refs.isEmpty else { return }
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
        for (id, key) in [(UInt32(1), kVK_ANSI_A), (2, kVK_Space)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                                EventHotKeyID(signature: OSType(0x44534846), id: id),
                                GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
        refs = []; handler = nil
    }
}
