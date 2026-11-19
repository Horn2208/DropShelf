import AppKit
import UniformTypeIdentifiers

/// Opt-in Spaß beim Aufploppen einer Ablage: eigener Sound und Vollbild-Bildblitz.
/// Dateien werden in Application Support kopiert (kein Security-Scope nötig).
@MainActor
enum FunEffects {
    private static var sound: NSSound?
    private static var flashWindow: NSWindow?

    static func onPop(screen: NSScreen?) {
        let d = UserDefaults.standard
        if d.bool(forKey: "funSoundEnabled") { playSound() }
        if d.bool(forKey: "funImageEnabled") { flash(on: screen) }
    }

    static func playSound() {
        guard let p = UserDefaults.standard.string(forKey: "funSoundPath") else { return }
        sound?.stop()
        sound = NSSound(contentsOfFile: p, byReference: true)
        sound?.play()
    }

    /// Bild 1 s über den ganzen Bildschirm; nie Fokus, nie klickbar. Nur ein Blitz gleichzeitig.
    static func flash(on screen: NSScreen?) {
        guard flashWindow == nil, let screen = screen ?? NSScreen.main,
              let p = UserDefaults.standard.string(forKey: "funImagePath"),
              let img = NSImage(contentsOfFile: p) else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        v.layer?.contents = img
        v.layer?.contentsGravity = .resizeAspectFill
        w.contentView = v
        w.alphaValue = 0
        w.orderFrontRegardless()  // ohne Aktivierung
        flashWindow = w
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; w.animator().alphaValue = 1 }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; w.animator().alphaValue = 0 }, completionHandler: {
                    MainActor.assumeIsolated { w.orderOut(nil); if flashWindow === w { flashWindow = nil } }
                })
            }
        })
    }

    /// Kopiert `url` nach Application Support/DropShelf/fun/<prefix>-<name>; liefert den neuen Pfad.
    static func copyIn(_ url: URL, prefix: String) -> String? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DropShelf/fun", isDirectory: true) else { return nil }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix(prefix + "-") {
            try? fm.removeItem(at: f)
        }
        let dest = base.appendingPathComponent("\(prefix)-\(url.lastPathComponent)")
        do { try fm.copyItem(at: url, to: dest) } catch { return nil }
        return dest.path
    }

    static func pick(_ type: UTType, prefix: String, key: String) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [type]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url, let path = copyIn(u, prefix: prefix) else { return }
        UserDefaults.standard.set(path, forKey: key)
    }

    static func remove(prefix: String, key: String) {
        if let p = UserDefaults.standard.string(forKey: key) { try? FileManager.default.removeItem(atPath: p) }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
