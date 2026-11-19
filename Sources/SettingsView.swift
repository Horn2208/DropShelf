import ApplicationServices
import Carbon
import IOKit.hid
import ServiceManagement
import SwiftUI
import UserNotifications

/// Eigenes Fenster statt `Settings`-Szene: die Szene öffnet sich in reinen Menüleisten-Apps (LSUIElement) unzuverlässig.
@MainActor
enum SettingsOpener {
    private static var window: NSWindow?

    static func open() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "DropShelf Einstellungen"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)  // LSUIElement-App: sonst bleibt das Fenster hinten
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab().tabItem { Label("Allgemein", systemImage: "gearshape") }.tag("general")
            ActionsTab().tabItem { Label("Aktionen", systemImage: "square.grid.2x2") }.tag("actions")
            ShortcutsTab().tabItem { Label("Kürzel", systemImage: "keyboard") }.tag("shortcuts")
            AppearanceTab().tabItem { Label("Aussehen", systemImage: "paintbrush") }.tag("appearance")
            PermissionsTab().tabItem { Label("Berechtigungen", systemImage: "lock.shield") }.tag("perms")
            AboutTab().tabItem { Label("Über", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 480, height: 400)
    }
}

private struct GeneralTab: View {
    @AppStorage("openShelfOnLaunch") private var openOnLaunch = true
    @AppStorage("autoCloseWhenEmpty") private var autoClose = true
    @AppStorage("askClearAfterAirDrop") private var askClear = true
    @AppStorage("viewMode") private var mode = "grid"
    @AppStorage("historyEnabled") private var history = true
    @AppStorage("historyLimit") private var historyLimit = 30
    @State private var login = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Beim Start Ablage öffnen", isOn: $openOnLaunch)
                Toggle("Ablage schließen, wenn sie leer ist", isOn: $autoClose)
                Toggle("Nach AirDrop fragen, ob die Ablage geleert werden soll", isOn: $askClear)
                Picker("Standard-Ansicht", selection: $mode) {
                    Text("Raster").tag("grid"); Text("Liste").tag("list")
                }
            }
            Section {
                Toggle("Verlauf speichern", isOn: $history)
                Picker("Verlaufsgröße", selection: $historyLimit) {
                    ForEach([10, 30, 50], id: \.self) { Text("\($0) Ablagen").tag($0) }
                }
                .disabled(!history)
            }
            Section {
                Toggle("Beim Anmelden starten", isOn: Binding(get: { login == .enabled }, set: setLogin))
                Text("Status: \(Self.text(login))").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: historyLimit) { _ in HistoryStore.shared.trim() }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = error.localizedDescription }
        login = SMAppService.mainApp.status
    }

    static func text(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: "aktiv"
        case .requiresApproval: "wartet auf Freigabe in den Systemeinstellungen"
        case .notRegistered: "nicht registriert"
        case .notFound: "nicht gefunden"
        @unknown default: "unbekannt"
        }
    }
}

/// Aktionsknöpfe: Schalter und Reihenfolge per Ziehen; höchstens 5 aktiv.
private struct ActionsTab: View {
    @ObservedObject private var prefs = ActionPrefs.shared

    var body: some View {
        let full = prefs.enabled.count >= ActionPrefs.maxActive
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(prefs.ordered) { a in
                    let on = prefs.enabled.contains(a)
                    Toggle(isOn: Binding(get: { on }, set: { set(a, $0) })) {
                        Label(a.title, systemImage: a.symbol)
                    }
                    .disabled(!on && full)
                }
                .onMove { from, to in
                    var all = prefs.ordered
                    all.move(fromOffsets: from, toOffset: to)
                    prefs.enabled = all.filter(prefs.enabled.contains)
                }
            }
            Text(full ? "Es sind höchstens \(ActionPrefs.maxActive) Aktionen gleichzeitig möglich – erst eine ausschalten."
                      : "Reihenfolge per Ziehen ändern. Änderungen wirken sofort.")
                .font(.caption).foregroundStyle(full ? .orange : .secondary).padding(.horizontal, 20).padding(.bottom, 12)
        }
    }

    private func set(_ a: ShelfAction, _ on: Bool) {
        if on { if prefs.enabled.count < ActionPrefs.maxActive { prefs.enabled.append(a) } }
        else { prefs.enabled.removeAll { $0 == a } }
    }
}

private struct ShortcutsTab: View {
    @AppStorage("hotkeyShelfEnabled") private var shelfOn = true
    @AppStorage("hotkeyAirDropEnabled") private var airOn = true
    @AppStorage("hotkeyHistoryEnabled") private var histOn = true
    @AppStorage("shakeEnabled") private var shakeOn = true
    @AppStorage("shakeSensitivity") private var shakeSens = 0.5

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $shelfOn) { row("Neue Ablage an der Maus", 2) }
                Toggle(isOn: $airOn) { row("Aktive Ablage per AirDrop senden", 1) }
                Toggle(isOn: $histOn) { row("Verlauf öffnen", 3) }
            } footer: { Text("Zum Ändern das Feld anklicken und das neue Kürzel drücken (mindestens ⌃, ⌥ oder ⌘). Esc bricht ab.") }
            Section {
                Toggle("Schütteln erkennen", isOn: $shakeOn)
                VStack(alignment: .leading) {
                    Text("Empfindlichkeit")
                    Slider(value: $shakeSens, in: 0...1) { Text("Empfindlichkeit") } minimumValueLabel: { Text("niedrig") } maximumValueLabel: { Text("hoch") }
                }
                .disabled(!shakeOn)
            } footer: {
                Text("Schüttle beim Ziehen einer Datei die Maus hin und her, um eine neue Ablage an der Maus zu öffnen. Dafür braucht DropShelf die Berechtigung „Bedienungshilfen“ (Tab Berechtigungen).")
            }
        }
        .formStyle(.grouped)
        .onChange(of: shelfOn) { _ in HotKey.shared.sync() }
        .onChange(of: airOn) { _ in HotKey.shared.sync() }
        .onChange(of: histOn) { _ in HotKey.shared.sync() }
        .onChange(of: shakeOn) { on in
            ShakeDetector.shared.sync()
            if on, !AXIsProcessTrusted() { ShakeDetector.requestAccessibility() }  // nur auf Wunsch, nie beim Start
        }
    }

    private func row(_ title: String, _ id: UInt32) -> some View {
        HStack { Text(title); Spacer(); ShortcutRecorder(id: id) }
    }
}

/// Zeigt das Kürzel als Symbole; Klick startet die Aufnahme (nächster Tastendruck mit ⌃/⌥/⌘, Esc bricht ab).
private struct ShortcutRecorder: View {
    let id: UInt32
    @State private var combo: (code: Int, mods: Int)
    @State private var recording = false
    @State private var monitor: Any?

    init(id: UInt32) { self.id = id; _combo = State(initialValue: HotKey.combo(id)) }

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Kürzel drücken …" : Self.label(combo)) { recording ? stop() : start() }
                .font(.system(.body, design: .rounded)).frame(minWidth: 110)
            Button { save(HotKey.defaultCombo(id)) } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).help("Auf Standard zurücksetzen")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }  // Esc
            let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard m.contains(.control) || m.contains(.option) || m.contains(.command) else { NSSound.beep(); return nil }
            var carbon = 0
            if m.contains(.control) { carbon |= controlKey }
            if m.contains(.option) { carbon |= optionKey }
            if m.contains(.shift) { carbon |= shiftKey }
            if m.contains(.command) { carbon |= cmdKey }
            save((Int(e.keyCode), carbon))
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func save(_ c: (code: Int, mods: Int)) {
        stop()
        combo = c
        UserDefaults.standard.set(c.code, forKey: "hotkeyCode\(id)")
        UserDefaults.standard.set(c.mods, forKey: "hotkeyMods\(id)")
        HotKey.shared.sync()
    }

    static func label(_ c: (code: Int, mods: Int)) -> String {
        (c.mods & controlKey != 0 ? "⌃" : "") + (c.mods & optionKey != 0 ? "⌥" : "")
            + (c.mods & shiftKey != 0 ? "⇧" : "") + (c.mods & cmdKey != 0 ? "⌘" : "") + keyName(c.code)
    }

    /// Tastenname über das aktuelle Tastaturlayout; Sondertasten fest.
    private static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let s = special[code] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "Taste \(code)" }
        let layout = unsafeBitCast(ptr, to: CFData.self)
        var dead: UInt32 = 0, len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let ok = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return ok == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "Taste \(code)"
    }
}

private struct AppearanceTab: View {
    @AppStorage("glassIntensity") private var glass = 0.4
    @AppStorage("animationsEnabled") private var anim = true
    @AppStorage("funSoundEnabled") private var soundOn = false
    @AppStorage("funSoundPath") private var soundPath = ""
    @AppStorage("funImageEnabled") private var imageOn = false
    @AppStorage("funImagePath") private var imagePath = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Glas-Intensität")
                    Slider(value: $glass, in: 0...1) { Text("Glas-Intensität") } minimumValueLabel: { Text("klar") } maximumValueLabel: { Text("dunkel") }
                }
                Toggle("Animationen", isOn: $anim)
                Text("„Bewegung reduzieren“ in den Systemeinstellungen wird zusätzlich beachtet (nur Einblenden).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spaß") {
                Toggle("Sound beim Aufploppen", isOn: $soundOn)
                HStack {
                    Text(soundPath.isEmpty ? "Kein Sound gewählt" : (soundPath as NSString).lastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Sound wählen…") { FunEffects.pick(.audio, prefix: "sound", key: "funSoundPath") }
                    Button("Vorhören") { FunEffects.playSound() }.disabled(soundPath.isEmpty)
                    Button("Entfernen") { FunEffects.remove(prefix: "sound", key: "funSoundPath") }.disabled(soundPath.isEmpty)
                }
                Toggle("Bild beim Aufploppen einblenden", isOn: $imageOn)
                Text("Vorsicht bei Lichtempfindlichkeit.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(imagePath.isEmpty ? "Kein Bild gewählt" : (imagePath as NSString).lastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Bild wählen…") { FunEffects.pick(.image, prefix: "image", key: "funImagePath") }
                    Button("Vorschau") { FunEffects.flash(on: NSScreen.main) }.disabled(imagePath.isEmpty)
                    Button("Entfernen") { FunEffects.remove(prefix: "image", key: "funImagePath") }.disabled(imagePath.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private enum PermState {
    case granted, denied, notNeeded
    var color: Color { self == .granted ? .green : self == .denied ? .gray : .orange }
    var text: String { self == .granted ? "erteilt" : self == .denied ? "nicht erteilt" : "nicht nötig" }
}

private struct PermissionsTab: View {
    @State private var ax = PermState.denied
    @State private var input = PermState.denied
    @State private var notif = PermState.notNeeded
    @State private var login = SMAppService.mainApp.status
    @State private var bookmarks = 0
    @State private var confirm = false

    var body: some View {
        Form {
            Section {
                row("Bedienungshilfen", "Nötig, damit DropShelf das Schütteln beim Ziehen einer Datei bemerkt. DropShelf liest dabei nur die Mausbewegung, keine Tasten oder Inhalte.", ax, "Privacy_Accessibility")
                row("Eingabeüberwachung", "Maus-Gesten global verfolgen (nur falls macOS danach fragt).", input, "Privacy_ListenEvent")
                row("Mitteilungen", "Wird aktuell nicht benötigt.", notif, "Notifications")
                row("Anmeldeobjekt", "Start beim Anmelden: \(GeneralTab.text(login)).",
                    login == .enabled ? .granted : .denied, "LoginItems")
            }
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Ordner-/Dateizugriff")
                        Text("\(bookmarks) gespeicherte Zugriffe (Lesezeichen) für Dateien in Ablagen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Zurücksetzen…") { confirm = true }.disabled(bookmarks == 0)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Gespeicherte Zugriffe zurücksetzen?", isPresented: $confirm) {
            Button("Zurücksetzen", role: .destructive) { ShelfManager.shared.resetBookmarks(); bookmarks = ShelfManager.shared.bookmarkCount }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Ablagen bleiben bis zum Beenden gefüllt, werden danach aber nicht wiederhergestellt.") }
        .task {
            while !Task.isCancelled {  // alle 2 s, nur solange der Tab sichtbar ist
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func row(_ title: String, _ hint: String, _ state: PermState, _ pane: String) -> some View {
        HStack {
            Circle().fill(state.color).frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text("\(title) – \(state.text)")
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pane == "Privacy_Accessibility", state != .granted {
                Button("Erlauben…") { ShakeDetector.requestAccessibility() }
            }
            Button("Öffnen…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") ?? nil,
                   !NSWorkspace.shared.open(url) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
                }
            }
        }
    }

    private func refresh() async {
        ax = AXIsProcessTrusted() ? .granted : .denied
        input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? .granted : .denied
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notif = status == .authorized || status == .provisional ? .granted : .notNeeded
        login = SMAppService.mainApp.status
        bookmarks = ShelfManager.shared.bookmarkCount
    }
}

private struct AboutTab: View {
    var body: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 40, weight: .thin))
            Text("DropShelf").font(.title2.weight(.semibold))
            Text("Version \(v)").foregroundStyle(.secondary)
            Link("github.com/Horn2208/DropShelf", destination: URL(string: "https://github.com/Horn2208/DropShelf")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
