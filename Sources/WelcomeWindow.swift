import SwiftUI
import AppKit

/// Einmalige Namensabfrage beim ersten Start (nur wenn noch kein Name gesetzt ist).
@MainActor
enum WelcomeWindow {
    private static let askedKey = "didAskForName"
    private static var window: NSWindow?

    static func showIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: askedKey),
              (d.string(forKey: NameBadge.nameKey) ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let host = NSHostingController(rootView: AnyView(WelcomeView(done: close).milkyCobalt()))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = "Willkommen"
        w.setContentSize(NSSize(width: 400, height: 580))
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)  // Menüleisten-App: sonst bleibt das Fenster hinten
        w.makeKeyAndOrderFront(nil)
    }

    private static func close() {
        UserDefaults.standard.set(true, forKey: askedKey)
        window?.close()
        window = nil
    }
}

private struct WelcomeView: View {
    let done: () -> Void
    @AppStorage(NameBadge.nameKey) private var name = ""
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Willkommen bei DropShelf").font(.system(size: 22, weight: .bold)).padding(.top, 20)
            Text("Wie heißt du? Dein Name kommt auf deine Karte.").font(.system(size: 13)).foregroundStyle(.secondary)
            NameBadge()
            TextField("Dein Name", text: $draft).textFieldStyle(.plain).multilineTextAlignment(.center)
                .padding(.vertical, 7).padding(.horizontal, 14).frame(width: 240)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .focused($focused)
                .onSubmit(save)
                .onChange(of: draft) { _, v in name = v }  // Karte zeigt live den Namen
            HStack(spacing: 10) {
                Button("Später") { name = ""; done() }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 12)
                Button("Los geht's", action: save).buttonStyle(.borderedProminent).tint(NordicCobalt.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func save() {
        name = draft.trimmingCharacters(in: .whitespaces)
        done()
    }
}
