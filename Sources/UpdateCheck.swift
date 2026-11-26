import AppKit
import Foundation

/// Reine Logik des Update-Hinweises (kein Netz, Uhr wird übergeben).
struct ReleaseInfo: Equatable, Sendable {
    let tag: String
    let url: URL
    var dmg: URL? = nil  // passendes DMG-Asset; nil -> nur Release-Seite
    var version: String { tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag }
}

enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/Horn2208/DropShelf/releases/latest")!
    static let interval: TimeInterval = 24 * 3600

    /// "v1.2.3" / "1.2" -> [1,2,3]; ungültig (leer, Buchstaben, negative Teile) -> nil.
    static func parseVersion(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// true, wenn `tag` echt neuer als `current` ist; ungültige Eingaben -> false. Fehlende Teile zählen als 0.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        guard var a = parseVersion(tag), var b = parseVersion(current) else { return false }
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count)
        b += Array(repeating: 0, count: n - b.count)
        return a.lexicographicallyPrecedes(b) ? false : a != b
    }

    /// Liest `tag_name`, `html_url` und das DMG-Asset aus der GitHub-Antwort; sonst nil.
    static func parseRelease(_ data: Data) -> ReleaseInfo? {
        struct A: Decodable { let name: String; let browser_download_url: String }
        struct R: Decodable { let tag_name: String; let html_url: String; let assets: [A]? }
        guard let r = try? JSONDecoder().decode(R.self, from: data), let u = URL(string: r.html_url),
              u.scheme == "https" else { return nil }
        let dmg = (r.assets ?? []).first {
            let n = $0.name.lowercased()
            return n.hasSuffix(".dmg") && !n.contains("troll")
        }.flatMap { URL(string: $0.browser_download_url) }.flatMap { isTrustedDownload($0) ? $0 : nil }
        return ReleaseInfo(tag: r.tag_name, url: u, dmg: dmg)
    }

    /// Nur https von github.com bzw. *.githubusercontent.com.
    static func isTrustedDownload(_ u: URL) -> Bool {
        guard u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return h == "github.com" || h == "githubusercontent.com" || h.hasSuffix(".githubusercontent.com")
    }

    /// `DropShelf-<version>.dmg` in `dir`; existiert er, ` 2`, ` 3` … – nie überschreiben.
    /// Version wird auf [A-Za-z0-9._-] reduziert (kommt aus dem Netz).
    static func downloadDestination(in dir: URL, version: String, fm: FileManager = .default) -> URL {
        var v = String(version.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }.map(Character.init))
        while v.hasPrefix(".") { v.removeFirst() }
        let base = v.isEmpty ? "DropShelf" : "DropShelf-\(v)"
        var n = 1
        while true {
            let u = dir.appendingPathComponent(n == 1 ? "\(base).dmg" : "\(base) \(n).dmg")
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    /// Drossel: höchstens einmal pro Tag. Uhr springt zurück -> wieder prüfen.
    static func shouldCheck(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let d = now.timeIntervalSince(last)
        return d >= interval || d < 0
    }
}

struct DownloadFailure: Error {
    let message: String
    init(_ m: String) { message = m }
}

/// Netz- und Zustandsschicht. Fehler/404 = still „kein Update“.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static let autoKey = "updateCheckEnabled"
    private static let lastKey = "updateLastCheck"

    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var message: String?  // nur nach manueller Prüfung
    @Published private(set) var checking = false

    private var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Beim Start: nur wenn Schalter an (Standard) und letzte Prüfung > 1 Tag her.
    func checkOnLaunch() {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.autoKey) as? Bool ?? true,
              UpdateCheck.shouldCheck(last: d.object(forKey: Self.lastKey) as? Date, now: Date()) else { return }
        Task { await check(manual: false) }
    }

    func checkNow() { Task { await check(manual: true) } }

    func openRelease() { if let u = available?.url { NSWorkspace.shared.open(u) } }

    // MARK: Herunterladen und öffnen (keine Installation, nichts wird ausgeführt)

    @Published private(set) var downloadProgress: Double?  // 0…1, nil = kein Download aktiv
    @Published private(set) var downloadStatus: String?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    /// Lädt das DMG nach ~/Downloads und öffnet (mountet) es.
    func downloadUpdate() {
        guard downloadTask == nil, let r = available else { return }
        guard let src = r.dmg else { downloadStatus = "Kein DMG im Release gefunden – bitte Release-Seite öffnen"; return }
        guard let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            downloadStatus = "Downloads-Ordner nicht gefunden"; return
        }
        var req = URLRequest(url: src, timeoutInterval: 60)
        req.setValue("DropShelf", forHTTPHeaderField: "User-Agent")
        let version = r.version
        let task = URLSession.shared.downloadTask(with: req) { tmp, resp, err in
            // Läuft im Hintergrund; tmp ist nur hier gültig, darum sofort verschieben.
            let outcome: Result<URL, DownloadFailure>
            if let e = err as? URLError, e.code == .cancelled { outcome = .failure(.init("Download abgebrochen")) }
            else if err != nil || tmp == nil { outcome = .failure(.init("Download fehlgeschlagen (Netzwerk)")) }
            else if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
                outcome = .failure(.init("Download fehlgeschlagen (HTTP \(code))"))
            } else if let tmp, ((try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 0 {
                outcome = .failure(.init("Download fehlgeschlagen (Datei leer)"))
            } else {
                let dest = UpdateCheck.downloadDestination(in: dir, version: version)
                // moveItem überschreibt nie; Kollision -> Fehler statt Datenverlust.
                if dest.pathExtension == "dmg", (try? FileManager.default.moveItem(at: tmp!, to: dest)) != nil {
                    outcome = .success(dest)
                } else { outcome = .failure(.init("Konnte nicht in „Downloads“ speichern")) }
            }
            Task { @MainActor in UpdateManager.shared.finishDownload(outcome) }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in
                let m = UpdateManager.shared
                if m.downloadTask != nil { m.downloadProgress = f }
            }
        }
        downloadTask = task
        downloadProgress = 0
        downloadStatus = "Lade Version \(version) …"
        task.resume()
    }

    func cancelDownload() { downloadTask?.cancel() }

    private func finishDownload(_ outcome: Result<URL, DownloadFailure>) {
        downloadTask = nil
        progressObservation = nil
        downloadProgress = nil
        switch outcome {
        case .success(let dmg):
            downloadStatus = NSWorkspace.shared.open(dmg)
                ? "DMG geöffnet – DropShelf in den Programme-Ordner ziehen, dann neu starten"
                : "DMG in „Downloads“ gespeichert, konnte aber nicht geöffnet werden"
        case .failure(let f): downloadStatus = f.message
        }
    }

    private func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        if manual { message = nil; if downloadTask == nil { downloadStatus = nil } }
        var req = URLRequest(url: UpdateCheck.endpoint, timeoutInterval: 15)
        req.setValue("DropShelf", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        var found: ReleaseInfo?
        var failed = true
        if let (data, resp) = try? await URLSession.shared.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode {
            if code == 200 { found = UpdateCheck.parseRelease(data); failed = found == nil }
            else if code == 404 { failed = false }  // noch keine Releases
        }
        if !failed { UserDefaults.standard.set(Date(), forKey: Self.lastKey) }
        available = found.flatMap { UpdateCheck.isNewer($0.tag, than: current) ? $0 : nil }
        if manual {
            message = failed ? "Prüfung nicht möglich" : available.map { "Neue Version \($0.version) verfügbar" } ?? "Du hast die neueste Version"
        }
    }
}
