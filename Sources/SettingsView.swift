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
            w.styleMask = [.titled, .closable]  // feste Größe: nicht skalierbar
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)  // LSUIElement-App: sonst bleibt das Fenster hinten
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case activation, interactions, general, appearance, actions, perms, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .activation: "Fensteraktivierung"
        case .interactions: "Fensterinteraktionen"
        case .general: "Allgemein"
        case .appearance: "Aussehen"
        case .actions: "Aktionen"
        case .perms: "Berechtigungen"
        case .about: "Über"
        }
    }
    var symbol: String {
        switch self {
        case .activation: "hand.draw"
        case .interactions: "rectangle.on.rectangle"
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .actions: "square.grid.2x2"
        case .perms: "lock.shield"
        case .about: "info.circle"
        }
    }
    var color: Color {
        switch self {
        case .activation: .blue
        case .interactions: .green
        case .general: .gray
        case .appearance: .purple
        case .actions: .orange
        case .perms: .red
        case .about: .gray
        }
    }
    var blurb: String {
        switch self {
        case .activation: "Wie und womit neue Ablagen erscheinen."
        case .interactions: "Wie sich Ablagen beim Benutzen verhalten."
        case .general: "Start, Verlauf und Grundverhalten der App."
        case .appearance: "Glas, Animationen und etwas Spaß."
        case .actions: "Die Knöpfe unter der Ablage – höchstens fünf gleichzeitig."
        case .perms: "Was macOS DropShelf erlaubt hat."
        case .about: "Version und Projektseite."
        }
    }
}

private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsSection.activation.rawValue

    var body: some View {
        let current = SettingsSection(rawValue: tab) ?? .activation
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { s in
                    Button { tab = s.rawValue } label: {
                        HStack(spacing: 9) {
                            SidebarIcon(symbol: s.symbol, color: s.color)
                            Text(s.title).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(s == current ? 0.1 : 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("DropShelf").font(.system(size: 12, weight: .semibold))
                        Text(appVersion).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(10)
            .frame(width: 210)
            .background(.quaternary.opacity(0.5))
            Divider()
            SettingsPage(section: current) {
                switch current {
                case .activation: ActivationPage()
                case .interactions: InteractionsPage()
                case .general: GeneralPage()
                case .appearance: AppearancePage()
                case .actions: ActionsPage()
                case .perms: PermissionsPage()
                case .about: AboutPage()
                }
            }
            .id(current)
        }
        .frame(width: 720, height: 520)
    }
}

// MARK: Bausteine

struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct SettingsPage<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text(section.title).font(.system(size: 24, weight: .bold))
                    Text(section.blurb).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.top, 22).padding(.bottom, 6)
                content
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Gruppierte Karte; Zeilen mit `SettingsDivider` trennen.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
}

private struct SettingsRow<Control: View>: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    @ViewBuilder let control: Control
    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image.symbol(symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

private struct SettingsToggleRow: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var body: some View {
        SettingsRow(symbol: symbol, title: title, subtitle: subtitle) { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
    }
}

private func footnote(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
}

private func sliderControl(_ value: Binding<Double>, _ low: String, _ high: String) -> some View {
    HStack(spacing: 6) {
        Text(low).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        Slider(value: value, in: 0...1).frame(width: 110)
        Text(high).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
    }
}

// MARK: Seiten

private struct ActivationPage: View {
    @AppStorage("hotkeyShelfEnabled") private var shelfOn = true
    @AppStorage("hotkeyClipboardEnabled") private var clipOn = true
    @AppStorage("hotkeyAirDropEnabled") private var airOn = true
    @AppStorage("hotkeyHistoryEnabled") private var histOn = true
    @AppStorage("shakeEnabled") private var shakeOn = true
    @AppStorage("shakeSensitivity") private var shakeSens = 0.5
    @AppStorage("shakeModifier") private var modifier = "none"

    var body: some View {
        SettingsCard {
            SettingsToggleRow(symbol: "hand.draw", title: "Schütteln beim Ziehen",
                        subtitle: "Beim Ziehen einer Datei die Maus hin und her bewegen. Braucht „Bedienungshilfen“.", isOn: $shakeOn)
            SettingsDivider()
            SettingsRow(symbol: "dial.medium", title: "Empfindlichkeit") { sliderControl($shakeSens, "niedrig", "hoch") }
                .disabled(!shakeOn)
            SettingsDivider()
            SettingsRow(symbol: "option", title: "Mit Modifikatortaste aktivieren",
                        subtitle: "Beim Ziehen mit gehaltener Taste öffnet sich sofort eine Ablage.") {
                Picker("", selection: $modifier) {
                    Text("Aus").tag("none"); Text("⇧ Umschalt").tag("shift"); Text("⌥ Wahl").tag("option")
                    Text("⌃ Control").tag("control"); Text("⌘ Befehl").tag("command")
                }
                .labelsHidden().frame(width: 120)
            }
        }
        SettingsCard {
            shortcut("Neue Ablage an der Maus", "plus.rectangle.on.rectangle", 2, $shelfOn)
            SettingsDivider()
            shortcut("Ablage aus Zwischenablage", "doc.on.clipboard", 4, $clipOn)
            SettingsDivider()
            shortcut("Aktive Ablage per AirDrop", "airdrop", 1, $airOn)
            SettingsDivider()
            shortcut("Verlauf öffnen", "clock.arrow.circlepath", 3, $histOn)
        }
        footnote("Zum Ändern das Feld anklicken und das neue Kürzel drücken (mindestens ⌃, ⌥ oder ⌘). Esc bricht ab. „Neue Ablage an der Maus“ öffnet sie dort, wo der Mauszeiger steht.")
            .onChange(of: shelfOn) { _ in HotKey.shared.sync() }
            .onChange(of: clipOn) { _ in HotKey.shared.sync() }
            .onChange(of: airOn) { _ in HotKey.shared.sync() }
            .onChange(of: histOn) { _ in HotKey.shared.sync() }
            .onChange(of: modifier) { _ in ShakeDetector.shared.sync() }
            .onChange(of: shakeOn) { on in
                ShakeDetector.shared.sync()
                if on, !AXIsProcessTrusted() { ShakeDetector.requestAccessibility() }  // nur auf Wunsch, nie beim Start
            }
    }

    private func shortcut(_ title: String, _ symbol: String, _ id: UInt32, _ on: Binding<Bool>) -> some View {
        SettingsRow(symbol: symbol, title: title) {
            HStack(spacing: 10) {
                ShortcutRecorder(id: id)
                Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}

private struct InteractionsPage: View {
    @AppStorage("autoCloseWhenEmpty") private var autoClose = true
    @AppStorage("askClearAfterAirDrop") private var askClear = true
    @AppStorage("viewMode") private var mode = "grid"

    var body: some View {
        SettingsCard {
            SettingsToggleRow(symbol: "xmark.rectangle", title: "Ablage schließen, wenn sie leer ist",
                        subtitle: "Nach dem Herausziehen der letzten Datei schließt sich das Fenster.", isOn: $autoClose)
            SettingsDivider()
            SettingsToggleRow(symbol: "airdrop", title: "Nach AirDrop fragen",
                        subtitle: "Ob die Ablage nach dem Senden geleert werden soll.", isOn: $askClear)
            SettingsDivider()
            SettingsRow(symbol: "square.grid.2x2", title: "Standard-Ansicht") {
                Picker("", selection: $mode) { Text("Raster").tag("grid"); Text("Liste").tag("list") }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 140)
            }
        }
    }
}

private struct GeneralPage: View {
    @AppStorage("openShelfOnLaunch") private var openOnLaunch = true
    @AppStorage("historyEnabled") private var history = true
    @AppStorage("historyLimit") private var historyLimit = 30
    @State private var login = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        SettingsCard {
            SettingsToggleRow(symbol: "power", title: "Beim Anmelden starten",
                        subtitle: "Status: \(loginText(login))",
                        isOn: Binding(get: { login == .enabled }, set: setLogin))
            SettingsDivider()
            SettingsToggleRow(symbol: "tray.and.arrow.down", title: "Beim Start Ablage öffnen",
                        subtitle: "Öffnet eine leere Ablage, wenn keine andere offen ist.", isOn: $openOnLaunch)
        }
        if let error { footnote(error).foregroundStyle(.red) }
        SettingsCard {
            SettingsToggleRow(symbol: "clock.arrow.circlepath", title: "Verlauf speichern",
                        subtitle: "Geschlossene und geleerte Ablagen bleiben wiederherstellbar.", isOn: $history)
            SettingsDivider()
            SettingsRow(symbol: "number", title: "Verlaufsgröße") {
                Picker("", selection: $historyLimit) {
                    ForEach([10, 30, 50], id: \.self) { Text("\($0) Ablagen").tag($0) }
                }
                .labelsHidden().frame(width: 120)
            }
            .disabled(!history)
        }
        .onChange(of: historyLimit) { _ in HistoryStore.shared.trim() }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = error.localizedDescription }
        login = SMAppService.mainApp.status
    }
}

private func loginText(_ s: SMAppService.Status) -> String {
    switch s {
    case .enabled: "aktiv"
    case .requiresApproval: "wartet auf Freigabe in den Systemeinstellungen"
    case .notRegistered: "nicht registriert"
    case .notFound: "nicht gefunden"
    @unknown default: "unbekannt"
    }
}

private struct AppearancePage: View {
    @AppStorage("glassIntensity") private var glass = 0.25
    @AppStorage("liquidRefraction") private var refraction = true
    @AppStorage("refractionStrength") private var strength = 0.6
    @AppStorage("refractionReach") private var reach = 0.5
    @AppStorage("animationsEnabled") private var anim = true
    @AppStorage("funSoundEnabled") private var soundOn = false
    @AppStorage("funSoundPath") private var soundPath = ""
    @AppStorage("funImageEnabled") private var imageOn = false
    @AppStorage("funImagePath") private var imagePath = ""

    var body: some View {
        SettingsCard {
            SettingsRow(symbol: "circle.lefthalf.filled", title: "Glas-Intensität") { sliderControl($glass, "klar", "dunkel") }
            if GlassKit.liquid {
                SettingsDivider()
                SettingsToggleRow(symbol: "sparkles", title: "Liquid Glass mit Lichtbrechung",
                            subtitle: "Der Inhalt hinter der Ablage wird am Rand wie durch dickes Glas verbogen.", isOn: $refraction)
                SettingsDivider()
                SettingsRow(symbol: "camera.filters", title: "Lichtbrechung am Rand") { sliderControl($strength, "leicht", "stark") }
                    .disabled(!refraction)
                SettingsDivider()
                SettingsRow(symbol: "arrow.left.and.right", title: "Reichweite der Lichtbrechung") { sliderControl($reach, "schmal", "breit") }
                    .disabled(!refraction)
                SettingsDivider()
                SettingsRow(symbol: "drop", title: "Klares Glas mit starker Lichtbrechung") {
                    Button("Wie Canopy") { glass = 0.1; refraction = true; strength = 1; reach = 0.7 }.controlSize(.small)
                }
            }
            SettingsDivider()
            SettingsToggleRow(symbol: "wand.and.stars", title: "Animationen",
                        subtitle: "„Bewegung reduzieren“ in den Systemeinstellungen wird zusätzlich beachtet (nur Einblenden).", isOn: $anim)
        }
        Text("Spaß").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.top, 4)
        SettingsCard {
            SettingsToggleRow(symbol: "speaker.wave.2", title: "Sound beim Aufploppen", isOn: $soundOn)
            SettingsDivider()
            fileRow(soundPath, "Kein Sound gewählt") {
                Button("Wählen…") { FunEffects.pick(.audio, prefix: "sound", key: "funSoundPath") }
                Button("Vorhören") { FunEffects.playSound() }.disabled(soundPath.isEmpty)
                Button("Entfernen") { FunEffects.remove(prefix: "sound", key: "funSoundPath") }.disabled(soundPath.isEmpty)
            }
            SettingsDivider()
            SettingsToggleRow(symbol: "photo", title: "Bild beim Aufploppen einblenden",
                        subtitle: "Vorsicht bei Lichtempfindlichkeit.", isOn: $imageOn)
            SettingsDivider()
            fileRow(imagePath, "Kein Bild gewählt") {
                Button("Wählen…") { FunEffects.pick(.image, prefix: "image", key: "funImagePath") }
                Button("Vorschau") { FunEffects.flash(on: NSScreen.main) }.disabled(imagePath.isEmpty)
                Button("Entfernen") { FunEffects.remove(prefix: "image", key: "funImagePath") }.disabled(imagePath.isEmpty)
            }
        }
    }

    private func fileRow<B: View>(_ path: String, _ empty: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(spacing: 6) {
            Text(path.isEmpty ? empty : (path as NSString).lastPathComponent)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            buttons().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).padding(.leading, 32)
    }
}

/// Aktionsknöpfe: Schalter und Reihenfolge per Ziehen; höchstens 5 aktiv.
private struct ActionsPage: View {
    @ObservedObject private var prefs = ActionPrefs.shared

    var body: some View {
        let full = prefs.enabled.count >= ActionPrefs.maxActive
        SettingsCard {
            List {
                ForEach(prefs.ordered) { a in
                    let on = prefs.enabled.contains(a)
                    Toggle(isOn: Binding(get: { on }, set: { set(a, $0) })) {
                        Label { Text(a.title) } icon: { Image.symbol(a.symbol) }
                    }
                    .toggleStyle(.switch)
                    .disabled(!on && full)
                    .padding(.vertical, 3)
                }
                .onMove { from, to in
                    var all = prefs.ordered
                    all.move(fromOffsets: from, toOffset: to)
                    prefs.enabled = all.filter(prefs.enabled.contains)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
            .frame(height: CGFloat(prefs.ordered.count) * 36 + 12)
        }
        footnote(full ? "Es sind höchstens \(ActionPrefs.maxActive) Aktionen gleichzeitig möglich – erst eine ausschalten."
                      : "Reihenfolge per Ziehen ändern. Änderungen wirken sofort.")
            .foregroundStyle(full ? .orange : .secondary)
    }

    private func set(_ a: ShelfAction, _ on: Bool) {
        if on { if prefs.enabled.count < ActionPrefs.maxActive { prefs.enabled.append(a) } }
        else { prefs.enabled.removeAll { $0 == a } }
    }
}

/// Zeigt das Kürzel als Symbole; Klick startet die Aufnahme (nächster Tastendruck mit ⌃/⌥/⌘, Esc bricht ab).
struct ShortcutRecorder: View {
    let id: UInt32
    @State private var combo: (code: Int, mods: Int)
    @State private var recording = false
    @State private var monitor: Any?

    init(id: UInt32) { self.id = id; _combo = State(initialValue: HotKey.combo(id)) }

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Kürzel drücken …" : Self.label(combo)) { recording ? stop() : start() }
                .font(.system(.body, design: .rounded)).frame(minWidth: 96)
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
    static func keyName(_ code: Int) -> String {
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

private enum PermState {
    case granted, denied, notNeeded
    var color: Color { self == .granted ? .green : self == .denied ? .gray : .orange }
    var text: String { self == .granted ? "erteilt" : self == .denied ? "nicht erteilt" : "nicht nötig" }
}

private struct PermissionsPage: View {
    @State private var ax = PermState.denied
    @State private var input = PermState.denied
    @State private var notif = PermState.notNeeded
    @State private var login = SMAppService.mainApp.status
    @State private var bookmarks = 0
    @State private var confirm = false

    var body: some View {
        SettingsCard {
            row("Bedienungshilfen", "Nötig, damit DropShelf das Schütteln beim Ziehen einer Datei bemerkt. DropShelf liest dabei nur die Mausbewegung, keine Tasten oder Inhalte.", ax, "Privacy_Accessibility")
            SettingsDivider()
            row("Eingabeüberwachung", "Maus-Gesten global verfolgen (nur falls macOS danach fragt).", input, "Privacy_ListenEvent")
            SettingsDivider()
            row("Mitteilungen", "Wird aktuell nicht benötigt.", notif, "Notifications")
            SettingsDivider()
            row("Anmeldeobjekt", "Start beim Anmelden: \(loginText(login)).", login == .enabled ? .granted : .denied, "LoginItems")
        }
        SettingsCard {
            SettingsRow(symbol: "folder", title: "Ordner-/Dateizugriff",
                        subtitle: "\(bookmarks) gespeicherte Zugriffe (Lesezeichen) für Dateien in Ablagen.") {
                Button("Zurücksetzen…") { confirm = true }.disabled(bookmarks == 0)
            }
        }
        .confirmationDialog("Gespeicherte Zugriffe zurücksetzen?", isPresented: $confirm) {
            Button("Zurücksetzen", role: .destructive) { ShelfManager.shared.resetBookmarks(); bookmarks = ShelfManager.shared.bookmarkCount }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Ablagen bleiben bis zum Beenden gefüllt, werden danach aber nicht wiederhergestellt.") }
        .task {
            while !Task.isCancelled {  // alle 2 s, nur solange der Bereich sichtbar ist
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func row(_ title: String, _ hint: String, _ state: PermState, _ pane: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(state.color).frame(width: 10, height: 10).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(title) – \(state.text)").font(.system(size: 13))
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
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
        .padding(.horizontal, 12).padding(.vertical, 9)
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

private struct AboutPage: View {
    var body: some View {
        SettingsCard {
            SettingsRow(symbol: "info.circle", title: "DropShelf", subtitle: "Version \(appVersion)") { EmptyView() }
            SettingsDivider()
            SettingsRow(symbol: "link", title: "Projektseite") {
                Link("github.com/Horn2208/DropShelf", destination: URL(string: "https://github.com/Horn2208/DropShelf")!)
            }
        }
    }
}
