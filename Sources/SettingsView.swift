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
            w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            w.titleVisibility = .hidden  // Ampelknöpfe schweben über der Seitenleiste
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.setContentSize(NSSize(width: 660, height: 760))
            w.contentMinSize = NSSize(width: 640, height: 640)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)  // LSUIElement-App: sonst bleibt das Fenster hinten
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, clipboard, activation, interactions, actions, history, fun, perms, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "Allgemein"
        case .appearance: "Aussehen"
        case .shortcuts: "Kürzel"
        case .clipboard: "Zwischenablage"
        case .activation: "Aktivierung"
        case .interactions: "Interaktionen"
        case .actions: "Aktionen"
        case .history: "Verlauf"
        case .fun: "Spaß"
        case .perms: "Berechtigungen"
        case .about: "Über"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .shortcuts: "command"
        case .clipboard: "doc.on.clipboard"
        case .activation: "hand.draw"
        case .interactions: "rectangle.on.rectangle"
        case .actions: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        case .fun: "party.popper"
        case .perms: "lock.shield"
        case .about: "info.circle"
        }
    }
    /// Zusätzliche Suchbegriffe (Zeilentitel der Seite).
    var keywords: String {
        switch self {
        case .general: "Anmelden Start Ablage öffnen"
        case .appearance: "Glas Intensität Liquid Lichtbrechung Reichweite Canopy Animationen"
        case .shortcuts: "Tastenkürzel Hotkey Neue Ablage Zwischenablage AirDrop Verlauf"
        case .clipboard: "Verlauf kopiert Text Bilder Dateien Limit Ausgeschlossene Apps Löschen Passwort ⌃V"
        case .activation: "Schütteln Empfindlichkeit Modifikatortaste"
        case .interactions: "Schließen leer AirDrop fragen Ansicht Raster Liste Umwandeln Ersetzen nachfragen"
        case .actions: "Knöpfe Quick Look ZIP Teilen Finder Pfade"
        case .history: "Verlauf speichern Größe"
        case .fun: "Sound Bild Aufploppen"
        case .perms: "Bedienungshilfen Eingabeüberwachung Mitteilungen Ordner Dateizugriff"
        case .about: "Version Projektseite"
        }
    }
    func matches(_ q: String) -> Bool { q.isEmpty || title.localizedStandardContains(q) || keywords.localizedStandardContains(q) }
}

private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

private struct QueryKey: EnvironmentKey { static let defaultValue = "" }
private extension EnvironmentValues {
    var settingsQuery: String { get { self[QueryKey.self] } set { self[QueryKey.self] = newValue } }
}

/// Blendet eine Zeile aus, wenn die Suche ihren Titel nicht trifft.
private struct SearchFilter: ViewModifier {
    @Environment(\.settingsQuery) private var q
    let title: String
    func body(content: Content) -> some View {
        if q.isEmpty || title.localizedStandardContains(q) { content }
    }
}

private extension View {
    func searchTitle(_ t: String) -> some View { modifier(SearchFilter(title: t)) }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsSection.general.rawValue
    @State private var query = ""
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let top: [SettingsSection] = [.general, .appearance, .shortcuts, .clipboard]
    private let tray: [SettingsSection] = [.activation, .interactions, .actions, .history, .fun]
    private let bottom: [SettingsSection] = [.perms, .about]

    var body: some View {
        let current = SettingsSection(rawValue: tab) ?? .general
        HStack(spacing: 0) {
            sidebar(current)
                .frame(width: 196)
                .background(Color.primary.opacity(0.04).ignoresSafeArea())
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).ignoresSafeArea()
            SettingsPage(section: current) {
                switch current {
                case .general: GeneralPage()
                case .appearance: AppearancePage()
                case .shortcuts: ShortcutsPage()
                case .clipboard: ClipboardPage()
                case .activation: ActivationPage()
                case .interactions: InteractionsPage()
                case .actions: ActionsPage()
                case .history: HistoryPage()
                case .fun: FunPage()
                case .perms: PermissionsPage()
                case .about: AboutPage()
                }
            }
            .id(current)
            .environment(\.settingsQuery, query)
        }
        .frame(minWidth: 640, idealWidth: 660, minHeight: 640, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    private func sidebar(_ current: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                TextField("Suchen", text: $query).textFieldStyle(.plain).font(.system(size: 15))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 12).padding(.top, 46).padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group(top, current)
                    if tray.contains(where: { $0.matches(query) }) {
                        if top.contains(where: { $0.matches(query) }) { divider }
                        header("Ablage")
                    }
                    group(tray, current)
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)

            VStack(alignment: .leading, spacing: 2) {
                if bottom.contains(where: { $0.matches(query) }) { divider }
                group(bottom, current)
            }
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 12)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 8)
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)
    }

    @ViewBuilder private func group(_ items: [SettingsSection], _ current: SettingsSection) -> some View {
        ForEach(items.filter { $0.matches(query) }) { s in
            SidebarRow(section: s, selected: s == current, ns: ns, reduceMotion: reduceMotion) {
                if reduceMotion { tab = s.rawValue } else { withAnimation(.easeOut(duration: 0.18)) { tab = s.rawValue } }
            }
        }
    }
}

// MARK: Bausteine

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let ns: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SidebarIcon(symbol: section.symbol)
                Text(section.title).font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hover && !selected ? 0.06 : 0))
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.12))
                            .matchedGeometryEffect(id: "selection", in: ns)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in if reduceMotion { hover = h } else { withAnimation(.easeOut(duration: 0.12)) { hover = h } } }
    }
}

struct SidebarIcon: View {
    let symbol: String
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .regular)).foregroundStyle(.primary.opacity(0.9))
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size / 4, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

private struct SettingsPage<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: section.symbol).font(.system(size: 28, weight: .light))
                    Text(section.title).font(.system(size: 30, weight: .bold))
                }
                .padding(.top, 44)
                if section == .general { Hero() }
                content
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Hero: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .padding(.bottom, 6)
            Text("DropShelf").font(.system(size: 22, weight: .bold))
            Text("Version \(appVersion)").font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(NordicCobalt.deep.opacity(0.35))
                RadialGradient(colors: [NordicCobalt.accent.opacity(0.55), .clear],
                               center: .center, startRadius: 0, endRadius: 230)
            }
            .mask(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// Gruppe: grauer Titel oberhalb, Karte, optionale Fußnote darunter.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    var footerColor: Color = .secondary
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 6) }
            SettingsCard { content }
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(footerColor).padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.bottom, -1)  // letzte Trennlinie liegt außerhalb und wird abgeschnitten
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct SettingsRow<Control: View>: View {
    var symbol: String?
    var dot: Color?
    let title: String
    var subtitle: String?
    @ViewBuilder let control: Control
    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image.symbol(symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 24)
            }
            if let dot { Circle().fill(dot).frame(width: 10, height: 10).frame(width: 24) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.leading, 16) }
        .searchTitle(title)
    }
}

private struct SettingsToggleRow: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var body: some View {
        SettingsRow(symbol: symbol, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.large)
        }
    }
}

private func sliderControl(_ value: Binding<Double>, _ low: String, _ high: String) -> some View {
    HStack(spacing: 6) {
        Text(low).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
        Slider(value: value, in: 0...1).frame(width: 100)
        Text(high).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
    }
}

/// „Wert ⌄“-Menü ohne Rahmen.
private func menuPicker<T: Hashable, C: View>(_ sel: Binding<T>, @ViewBuilder _ items: () -> C) -> some View {
    Picker("", selection: sel, content: items).labelsHidden().pickerStyle(.menu).menuStyle(.borderlessButton).fixedSize()
}

// MARK: Seiten

private struct GeneralPage: View {
    @AppStorage("openShelfOnLaunch") private var openOnLaunch = true
    @State private var login = SMAppService.mainApp.status
    @State private var error: String?
    @AppStorage(UpdateManager.autoKey) private var autoUpdate = true
    @ObservedObject private var updates = UpdateManager.shared

    var body: some View {
        VStack(spacing: 20) { startGroup; updateGroup }
    }

    private var updateGroup: some View {
        SettingsGroup(title: "Updates", footer: updates.downloadStatus ?? updates.message) {
            SettingsToggleRow(symbol: "arrow.triangle.2.circlepath", title: "Automatisch nach Updates suchen",
                              subtitle: "Prüft beim Start höchstens einmal täglich auf GitHub.", isOn: $autoUpdate)
            SettingsRow(symbol: "arrow.down.circle", title: "Jetzt prüfen") {
                HStack {
                    if let r = updates.available { Button("Version \(r.version) öffnen") { updates.openRelease() } }
                    if let p = updates.downloadProgress {
                        ProgressView(value: p).frame(width: 80)
                        Button("Abbrechen") { updates.cancelDownload() }
                    } else if updates.available != nil {
                        Button("Herunterladen und öffnen") { updates.downloadUpdate() }
                    }
                    Button("Jetzt prüfen") { updates.checkNow() }.disabled(updates.checking)
                }
            }
        }
    }

    private var startGroup: some View {
        SettingsGroup(title: "Start", footer: error, footerColor: NordicCobalt.error) {
            SettingsToggleRow(symbol: "power", title: "Beim Anmelden starten",
                              subtitle: "Status: \(loginText(login))",
                              isOn: Binding(get: { login == .enabled }, set: setLogin))
            SettingsToggleRow(symbol: "tray.and.arrow.down", title: "Beim Start Ablage öffnen",
                              subtitle: "Öffnet eine leere Ablage, wenn keine andere offen ist.", isOn: $openOnLaunch)
        }
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

    var body: some View {
        SettingsGroup(title: "Glas") {
            SettingsRow(symbol: "circle.lefthalf.filled", title: "Glas-Intensität") { sliderControl($glass, "klar", "dunkel") }
            if GlassKit.liquid {
                SettingsToggleRow(symbol: "sparkles", title: "Liquid Glass mit Lichtbrechung",
                                  subtitle: "Der Inhalt hinter der Ablage wird am Rand wie durch dickes Glas verbogen.", isOn: $refraction)
                SettingsRow(symbol: "camera.filters", title: "Lichtbrechung am Rand") { sliderControl($strength, "leicht", "stark") }
                    .disabled(!refraction)
                SettingsRow(symbol: "arrow.left.and.right", title: "Reichweite der Lichtbrechung") { sliderControl($reach, "schmal", "breit") }
                    .disabled(!refraction)
                SettingsRow(symbol: "drop", title: "Klares Glas mit starker Lichtbrechung") {
                    Button("Wie Canopy") { glass = 0.1; refraction = true; strength = 1; reach = 0.7 }.controlSize(.regular)
                }
            }
        }
        SettingsGroup(title: "Bewegung",
                      footer: "„Bewegung reduzieren“ in den Systemeinstellungen wird zusätzlich beachtet (nur Einblenden).") {
            SettingsToggleRow(symbol: "wand.and.stars", title: "Animationen", isOn: $anim)
        }
    }
}

private struct ShortcutsPage: View {
    @AppStorage("hotkeyShelfEnabled") private var shelfOn = true
    @AppStorage("hotkeyClipboardEnabled") private var clipOn = true
    @AppStorage("hotkeyAirDropEnabled") private var airOn = true
    @AppStorage("hotkeyHistoryEnabled") private var histOn = true
    @AppStorage("hotkeyClipHistoryEnabled") private var clipHistOn = true
    @AppStorage("hotkeyFinderEnabled") private var finderOn = true

    var body: some View {
        SettingsGroup(title: "Globale Kürzel",
                      footer: "AirDrop sendet die aktive Ablage. Zum Ändern das Feld anklicken und das neue Kürzel drücken (mindestens ⌃, ⌥ oder ⌘). Esc bricht ab. „Neue Ablage“ öffnet sie dort, wo der Mauszeiger steht.") {
            shortcut("Neue Ablage", "plus.rectangle.on.rectangle", 2, $shelfOn)
            shortcut("Zwischenablage", "doc.on.clipboard", 4, $clipOn)
            shortcut("Aktive Ablage per AirDrop", "airdrop", 1, $airOn)
            shortcut("Verlauf öffnen", "clock.arrow.circlepath", 3, $histOn)
            shortcut("Zwischenablage-Verlauf", "doc.on.doc", 5, $clipHistOn)
            shortcut("Finder-Auswahl ins Shelf", "folder", 6, $finderOn)
        }
        .onChange(of: shelfOn) { _ in HotKey.shared.sync() }
        .onChange(of: clipOn) { _ in HotKey.shared.sync() }
        .onChange(of: airOn) { _ in HotKey.shared.sync() }
        .onChange(of: histOn) { _ in HotKey.shared.sync() }
        .onChange(of: clipHistOn) { _ in HotKey.shared.sync() }
        .onChange(of: finderOn) { _ in HotKey.shared.sync() }
    }

    private func shortcut(_ title: String, _ symbol: String, _ id: UInt32, _ on: Binding<Bool>) -> some View {
        SettingsRow(symbol: symbol, title: title) {
            HStack(spacing: 10) {
                ShortcutRecorder(id: id)
                Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.large)
            }
        }
    }
}

private struct ActivationPage: View {
    @AppStorage("shakeEnabled") private var shakeOn = true
    @AppStorage("shakeSensitivity") private var shakeSens = 0.5
    @AppStorage("shakeModifier") private var modifier = "none"

    var body: some View {
        SettingsGroup(title: "Schütteln",
                      footer: "Beim Ziehen einer Datei die Maus hin und her bewegen. Braucht „Bedienungshilfen“.") {
            SettingsToggleRow(symbol: "hand.draw", title: "Schütteln beim Ziehen", isOn: $shakeOn)
            SettingsRow(symbol: "dial.medium", title: "Empfindlichkeit") { sliderControl($shakeSens, "niedrig", "hoch") }
                .disabled(!shakeOn)
        }
        SettingsGroup(title: "Modifikatortaste", footer: "Beim Ziehen mit gehaltener Taste öffnet sich sofort eine Ablage.") {
            SettingsRow(symbol: "option", title: "Mit Modifikatortaste aktivieren") {
                menuPicker($modifier) {
                    Text("Aus").tag("none"); Text("⇧ Umschalt").tag("shift"); Text("⌥ Wahl").tag("option")
                    Text("⌃ Control").tag("control"); Text("⌘ Befehl").tag("command")
                }
            }
        }
        .onChange(of: modifier) { _ in ShakeDetector.shared.sync() }
        .onChange(of: shakeOn) { on in
            ShakeDetector.shared.sync()
            if on, !AXIsProcessTrusted() { ShakeDetector.requestAccessibility() }  // nur auf Wunsch, nie beim Start
        }
    }
}

private struct FileFormatsGroup: View {
    @State private var entries = FileFormats.load()
    @State private var text = ""
    @State private var category = FileFormats.Category.image
    private var ext: String? { FileFormats.normalize(text).flatMap { e in entries.contains { $0.ext == e } ? nil : e } }

    var body: some View {
        SettingsGroup(title: "Dateiformate", footer: "Zusätzliche Endungen, die wie Bilder, Dokumente oder Medien behandelt werden (z. B. heic, jxl).") {
            SettingsRow(symbol: "doc.badge.plus", title: "Endung hinzufügen") {
                HStack {
                    TextField("jxl", text: $text).textFieldStyle(.roundedBorder).frame(width: 80).onSubmit(add)
                    menuPicker($category) { ForEach(FileFormats.Category.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Button("Hinzufügen", action: add).disabled(ext == nil)
                }
            }
            ForEach(entries, id: \.self) { e in
                SettingsRow(symbol: nil, title: ".\(e.ext)", subtitle: "\(e.category.title)") {
                    Button { entries.removeAll { $0 == e }; FileFormats.save(entries) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Entfernen")
                }
            }
            ForEach(ConverterRegistry.packManifest.packs) { CodecPackRow(pack: $0) }
        }
    }

    private func add() {
        guard let ext else { return }
        entries.append(.init(ext: ext, category: category))
        FileFormats.save(entries)
        text = ""
    }
}

/// Status und Laden/Entfernen eines nachladbaren Codec-Pakets.
private struct CodecPackRow: View {
    let pack: Pack
    @State private var version: String?
    @State private var progress: Double?
    @State private var error: String?

    var body: some View {
        SettingsRow(symbol: "shippingbox", title: pack.formats.map { $0.uppercased() }.joined(separator: ", "),
                    subtitle: error ?? (version.map { "Geladen, Version \($0)" } ?? "Nicht geladen")) {
            if let progress {
                ProgressView(value: progress).frame(width: 90)
            } else if version != nil {
                Button("Entfernen") { PackRegistry.remove(pack.id); version = nil; ConvertMenu.resetCache() }
            } else {
                Button("Laden") { load() }
            }
        }
        .onAppear { version = PackRegistry.installedVersion(pack.id) }
    }

    private func load() {
        progress = 0; error = nil
        Task {
            do {
                try await PackInstall.run(pack) { p in Task { @MainActor in progress = p } }
                version = PackRegistry.installedVersion(pack.id)
            } catch { self.error = error.localizedDescription }
            progress = nil
        }
    }
}

private struct InteractionsPage: View {
    @AppStorage("autoCloseWhenEmpty") private var autoClose = true
    @AppStorage("autoCloseEmptyEnabled") private var idleOn = true
    @AppStorage("autoCloseEmptySeconds") private var idleSecs = 5.0
    @AppStorage("askClearAfterAirDrop") private var askClear = true
    @AppStorage("viewMode") private var mode = "grid"
    @AppStorage(ConvertPrefs.replaceKey) private var convertReplaces = true
    @AppStorage(ConvertPrefs.askKey) private var convertAsk = true

    var body: some View {
        SettingsGroup(title: "Umwandeln") {
            SettingsToggleRow(symbol: "arrow.triangle.2.circlepath", title: "Beim Umwandeln die Datei in der Ablage ersetzen",
                              subtitle: "Nur der Eintrag in der Ablage wird ausgetauscht, die Originaldatei bleibt unverändert. Aus: Die neue Datei kommt zusätzlich neben das Original und in die Ablage.", isOn: $convertReplaces)
            SettingsToggleRow(symbol: "questionmark.bubble", title: "Vor dem Umwandeln nachfragen",
                              subtitle: "Fragt jedes Mal, ob ersetzt oder als neue Datei hinzugefügt werden soll.", isOn: $convertAsk)
        }
        SettingsGroup(title: "Verhalten") {
            SettingsToggleRow(symbol: "xmark.rectangle", title: "Ablage schließen, wenn sie leer ist",
                              subtitle: "Nach dem Herausziehen der letzten Datei schließt sich das Fenster.", isOn: $autoClose)
            SettingsToggleRow(symbol: "timer", title: "Leere Ablage automatisch schließen",
                              subtitle: "Eine Ablage, in die nichts gelegt wird, schließt sich nach der eingestellten Zeit.", isOn: $idleOn)
            SettingsRow(symbol: "hourglass", title: "Nach \(Int(idleSecs)) s") {
                Slider(value: $idleSecs, in: 3...30, step: 1).frame(width: 140)
            }
            .disabled(!idleOn)
            SettingsToggleRow(symbol: "airdrop", title: "Nach AirDrop fragen",
                              subtitle: "Ob die Ablage nach dem Senden geleert werden soll.", isOn: $askClear)
            SettingsRow(symbol: "square.grid.2x2", title: "Standard-Ansicht") {
                menuPicker($mode) { Text("Raster").tag("grid"); Text("Liste").tag("list") }
            }
        }
        FileFormatsGroup()
    }
}

private struct ClipboardPage: View {
    @AppStorage("clipboardEnabled") private var on = true
    @AppStorage("clipboardLimit") private var limit = 200
    @AppStorage("clipboardImages") private var images = true
    @ObservedObject private var store = ClipboardStore.shared
    @State private var excluded = ClipboardStore.excluded

    var body: some View {
        SettingsGroup(title: "Zwischenablage-Verlauf",
                      footer: "⌃V öffnet den Verlauf an der Maus (Kürzel änderbar unter „Kürzel“). Achtung: In manchen Textfeldern bedeutet ⌃V „Seite runter“ (Emacs-Tastenbelegung). Mit Bedienungshilfen fügt ⏎ direkt in die vorige App ein, sonst wird nur kopiert.") {
            SettingsToggleRow(symbol: "doc.on.clipboard", title: "Verlauf aufzeichnen",
                              subtitle: "Merkt sich Text, Links, Bilder und Dateien. Nicht angepinnter Text wird nach 24 Stunden gelöscht. Passwörter werden nur übersprungen, wenn die Quell-App sie als vertraulich markiert oder ausgeschlossen ist. Aus Notizen oder Browser-Erweiterungen können sie im Verlauf landen: Pausiere die Aufzeichnung vorher.", isOn: $on)
            SettingsRow(symbol: store.pausedUntil == nil ? "pause.circle" : "play.circle",
                        title: store.pausedUntil == nil ? "5 Minuten pausieren" : "Aufzeichnung pausiert",
                        subtitle: store.pausedUntil.map { "Läuft um \($0.formatted(date: .omitted, time: .shortened)) automatisch weiter." }
                            ?? "Was du währenddessen kopierst, wird nicht gespeichert.") {
                Button(store.pausedUntil == nil ? "Pausieren" : "Fortsetzen") {
                    if store.pausedUntil == nil { store.pause() } else { store.endPause() }
                }
            }
            .disabled(!on)
            SettingsRow(symbol: "number", title: "Limit") {
                menuPicker($limit) { ForEach([50, 100, 200, 500], id: \.self) { Text("\($0) Einträge").tag($0) } }
            }
            .disabled(!on)
            SettingsToggleRow(symbol: "photo", title: "Bilder speichern", isOn: $images).disabled(!on)
        }
        SettingsGroup(title: "Ausgeschlossene Apps", footer: "Aus diesen Apps kopierte Inhalte werden nicht gespeichert.") {
            ForEach(excluded, id: \.self) { id in
                SettingsRow(symbol: "app", title: ClipboardStore.appName(id), subtitle: id) {
                    Button("Entfernen") { excluded.removeAll { $0 == id }; ClipboardStore.excluded = excluded }
                }
            }
            SettingsRow(symbol: "plus.app", title: "App hinzufügen…") { Button("Auswählen…", action: addApp) }
        }
        SettingsGroup {
            SettingsRow(symbol: "trash", title: "Verlauf löschen", subtitle: "\(store.entries.count) Einträge, davon \(store.entries.filter(\.pinned).count) angepinnt") {
                Button("Löschen…", action: clear).disabled(store.entries.isEmpty && !store.unreadable)
            }
        }
        .onChange(of: on) { _ in ClipboardStore.shared.sync() }
        .onChange(of: limit) { _ in ClipboardStore.shared.trim() }
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier, !excluded.contains(id) else { return }
        excluded.append(id)
        ClipboardStore.excluded = excluded
    }

    /// Angepinnte bleiben standardmäßig erhalten; „Alles löschen“ entfernt auch sie.
    private func clear() {
        let a = NSAlert()
        a.messageText = "Zwischenablage-Verlauf löschen?"
        a.informativeText = store.unreadable
            ? "Der gespeicherte Verlauf ist nicht lesbar und wird in beiden Fällen vollständig gelöscht, auch angepinnte Einträge darin."
            : "Angepinnte Einträge bleiben erhalten, wenn du „Ohne Angepinnte“ wählst."
        a.addButton(withTitle: "Ohne Angepinnte").hasDestructiveAction = true
        a.addButton(withTitle: "Alles löschen").hasDestructiveAction = true
        a.addButton(withTitle: "Abbrechen")
        switch a.runModal() {
        case .alertFirstButtonReturn: ClipboardStore.shared.clear(includingPinned: false)
        case .alertSecondButtonReturn: ClipboardStore.shared.clear(includingPinned: true)
        default: break
        }
    }
}

private struct HistoryPage: View {
    @AppStorage("historyEnabled") private var history = true
    @AppStorage("historyLimit") private var historyLimit = 30

    var body: some View {
        SettingsGroup(title: "Verlauf") {
            SettingsToggleRow(symbol: "clock.arrow.circlepath", title: "Verlauf speichern",
                              subtitle: "Geschlossene und geleerte Ablagen bleiben wiederherstellbar.", isOn: $history)
            SettingsRow(symbol: "number", title: "Verlaufsgröße") {
                menuPicker($historyLimit) { ForEach([10, 30, 50], id: \.self) { Text("\($0) Ablagen").tag($0) } }
            }
            .disabled(!history)
        }
        .onChange(of: historyLimit) { _ in HistoryStore.shared.trim() }
    }
}

private struct FunPage: View {
    @AppStorage("funSoundEnabled") private var soundOn = false
    @AppStorage("funSoundPath") private var soundPath = ""
    @AppStorage("funSoundMaxSeconds") private var maxSeconds = 10.0
    @AppStorage("funImageEnabled") private var imageOn = false
    @AppStorage("funImagePath") private var imagePath = ""

    var body: some View {
        SettingsGroup(title: "Sound") {
            SettingsToggleRow(symbol: "speaker.wave.2", title: "Sound beim Aufploppen", isOn: $soundOn)
            fileRow("Sound", soundPath, "Kein Sound gewählt") {
                Button("Wählen…") { FunEffects.pick(.audio, prefix: "sound", key: "funSoundPath") }
                Button("Vorhören") { FunEffects.playSound() }.disabled(soundPath.isEmpty)
                Button("Entfernen") { FunEffects.remove(prefix: "sound", key: "funSoundPath") }.disabled(soundPath.isEmpty)
            }
            SettingsRow(symbol: "timer", title: "Maximale Länge") {
                HStack(spacing: 8) {
                    Slider(value: $maxSeconds, in: 0.1...30, step: 0.1).frame(width: 140)
                    Text(maxSeconds.formatted(.number.precision(.fractionLength(1))) + " s").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
        SettingsGroup(title: "Bild", footer: "Vorsicht bei Lichtempfindlichkeit.") {
            SettingsToggleRow(symbol: "photo", title: "Bild beim Aufploppen einblenden", isOn: $imageOn)
            fileRow("Bild", imagePath, "Kein Bild gewählt") {
                Button("Wählen…") { FunEffects.pick(.image, prefix: "image", key: "funImagePath") }
                Button("Vorschau") { FunEffects.flash(on: NSScreen.main) }.disabled(imagePath.isEmpty)
                Button("Entfernen") { FunEffects.remove(prefix: "image", key: "funImagePath") }.disabled(imagePath.isEmpty)
            }
        }
    }

    private func fileRow<B: View>(_ title: String, _ path: String, _ empty: String, @ViewBuilder buttons: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(path.isEmpty ? empty : (path as NSString).lastPathComponent)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) { buttons().controlSize(.regular) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.leading, 16) }
        .searchTitle(title)
    }
}

/// Aktionsknöpfe: Schalter und Reihenfolge per Ziehen; höchstens 5 aktiv.
private struct ActionsPage: View {
    @ObservedObject private var prefs = ActionPrefs.shared

    var body: some View {
        let full = prefs.enabled.count >= ActionPrefs.maxActive
        SettingsGroup(title: "Knöpfe unter der Ablage",
                      footer: full ? "Es sind höchstens \(ActionPrefs.maxActive) Aktionen gleichzeitig möglich – erst eine ausschalten."
                                   : "Reihenfolge per Ziehen ändern. Änderungen wirken sofort.",
                      footerColor: full ? NordicCobalt.warning : .secondary) {
            List {
                ForEach(prefs.ordered) { a in
                    let on = prefs.enabled.contains(a)
                    Toggle(isOn: Binding(get: { on }, set: { set(a, $0) })) {
                        Label { Text(a.title) } icon: { Image.symbol(a.symbol) }.font(.system(size: 15))
                    }
                    .toggleStyle(.switch).controlSize(.large)
                    .disabled(!on && full)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    var all = prefs.ordered
                    all.move(fromOffsets: from, toOffset: to)
                    prefs.enabled = all.filter(prefs.enabled.contains)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
            .frame(height: CGFloat(prefs.ordered.count) * 46 + 12)
        }
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
        if (1...6).contains(where: { UInt32($0) != id && HotKey.combo(UInt32($0)) == c }) { NSSound.beep(); return }  // schon von einem anderen Kürzel belegt
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
    var color: Color { self == .granted ? NordicCobalt.success : self == .denied ? .gray : NordicCobalt.warning }
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
        SettingsGroup(title: "Systemrechte") {
            row("Bedienungshilfen", "Nötig, damit DropShelf das Schütteln beim Ziehen einer Datei bemerkt. DropShelf liest dabei nur die Mausbewegung, keine Tasten oder Inhalte.", ax, "Privacy_Accessibility")
            row("Eingabeüberwachung", "Maus-Gesten global verfolgen (nur falls macOS danach fragt).", input, "Privacy_ListenEvent")
            row("Mitteilungen", "Wird aktuell nicht benötigt.", notif, "Notifications")
            row("Anmeldeobjekt", "Start beim Anmelden: \(loginText(login)).", login == .enabled ? .granted : .denied, "LoginItems")
        }
        SettingsGroup(title: "Dateizugriff") {
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
        SettingsRow(dot: state.color, title: "\(title) – \(state.text)", subtitle: hint) {
            HStack(spacing: 8) {
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
        SettingsGroup(title: "DropShelf") {
            SettingsRow(symbol: "info.circle", title: "DropShelf", subtitle: "Version \(appVersion)") { EmptyView() }
            SettingsRow(symbol: "link", title: "Projektseite") {
                Link("github.com/Horn2208/DropShelf", destination: URL(string: "https://github.com/Horn2208/DropShelf")!)
            }
        }
    }
}
