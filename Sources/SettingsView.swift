import ApplicationServices
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

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $shelfOn) { row("Neue Ablage an der Maus", "⌃⌥Space") }
                Toggle(isOn: $airOn) { row("Aktive Ablage per AirDrop senden", "⌃⌥A") }
                Toggle(isOn: $histOn) { row("Verlauf öffnen", "⌃⌥V") }
            } footer: { Text("Eigene Kürzel festlegen folgt später.") }
        }
        .formStyle(.grouped)
        .onChange(of: shelfOn) { _ in HotKey.shared.sync() }
        .onChange(of: airOn) { _ in HotKey.shared.sync() }
        .onChange(of: histOn) { _ in HotKey.shared.sync() }
    }

    private func row(_ title: String, _ keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary) }
    }
}

private struct AppearanceTab: View {
    @AppStorage("glassIntensity") private var glass = 0.4
    @AppStorage("animationsEnabled") private var anim = true

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
                row("Bedienungshilfen", "Schütteln erkennen (ab Phase 6).", ax, "Privacy_Accessibility")
                row("Eingabeüberwachung", "Maus-Gesten global verfolgen (ab Phase 6).", input, "Privacy_ListenEvent")
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
