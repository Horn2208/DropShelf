import Foundation

enum RenameRule {
    case replace(find: String, with: String, regex: Bool)
    case affix(prefix: String, suffix: String)
    /// `Name - 1.ext`; width 2 gives `Name - 01.ext`.
    case counter(start: Int, width: Int)
    /// Datum als Präfix (`2026-11-25 - Name`) oder Suffix. `format` ist ein DateFormatter-Muster.
    case date(format: String, asPrefix: Bool, timeZone: TimeZone)
}

typealias RenameStep = (old: String, new: String, problem: String?)

enum Organize {
    /// Reine Funktion: Endung bleibt, Probleme werden pro Eintrag gemeldet (neuer Name = alter Name dann).
    static func renamePlan(_ names: [String], rule: RenameRule, dates: [Date]) -> [RenameStep] {
        var regex: NSRegularExpression?
        var ruleProblem: String?
        if case let .replace(find, _, true) = rule, !find.isEmpty {
            do { regex = try NSRegularExpression(pattern: find) } catch { ruleProblem = "Ungültiger regulärer Ausdruck" }
        }
        var counter = 0
        var steps: [RenameStep] = names.enumerated().map { i, old in
            if let ruleProblem { return (old, old, ruleProblem) }
            let ns = old as NSString
            let ext = ns.pathExtension
            let stem = ext.isEmpty ? old : ns.deletingPathExtension
            var newStem = stem
            switch rule {
            case let .replace(find, with, _):
                if find.isEmpty { break }
                if let regex {
                    newStem = regex.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: with)
                } else {
                    newStem = stem.replacingOccurrences(of: find, with: with)
                }
            case let .affix(prefix, suffix):
                newStem = prefix + stem + suffix
            case let .counter(start, width):
                let n = String(start + counter)
                counter += 1
                newStem = stem + " - " + String(repeating: "0", count: max(0, width - n.count)) + n
            case let .date(format, asPrefix, tz):
                guard i < dates.count else { return (old, old, "Kein Datum vorhanden") }
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = tz
                f.dateFormat = format
                let d = f.string(from: dates[i])
                newStem = asPrefix ? d + " - " + stem : stem + " - " + d
            }
            let new = ext.isEmpty ? newStem : newStem + "." + ext
            var problem: String?
            if newStem.isEmpty { problem = "Leerer Name" }
            else if new.contains("/") || new.contains(":") { problem = "Name enthält / oder :" }
            return (old, new, problem)
        }
        // Doppelte Ziele (APFS ist standardmäßig groß-/kleinschreibungsunabhängig).
        var count: [String: Int] = [:]
        for s in steps { count[s.new.lowercased(), default: 0] += 1 }
        for i in steps.indices where steps[i].problem == nil && count[steps[i].new.lowercased()]! > 1 {
            steps[i].problem = "Doppelter Zielname"
        }
        return steps
    }

    /// Inline-Umbenennen einer Datei: `newBase` ist der getippte Name ohne Endung, die Endung bleibt.
    /// Problem → neuer Name = alter Name. `exists` prüft, ob ein Name im Ordner schon belegt ist.
    static func renameStep(_ old: String, newBase: String, exists: (String) -> Bool) -> RenameStep {
        let base = newBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = base + ConvertMenu.split(old).ext
        if base.isEmpty { return (old, old, "Der Name darf nicht leer sein.") }
        if base.contains("/") || base.contains(":") { return (old, old, "Der Name darf kein „/“ oder „:“ enthalten.") }
        // Nur Groß-/Kleinschreibung geändert: dieselbe Datei (APFS), keine Kollision.
        if new.lowercased() != old.lowercased(), exists(new) { return (old, old, "„\(new)“ gibt es in diesem Ordner schon.") }
        return (old, new, nil)
    }
}

enum RenameError: LocalizedError, Equatable {
    case noWriteAccess(folder: String)
    case targetExists(String)
    case missing(String)
    case failed(String)
    /// Rückbau unvollständig: diese Dateien tragen noch einen Zwischennamen (Datei selbst ist unverändert).
    case rollbackIncomplete([String])

    var errorDescription: String? {
        switch self {
        case .noWriteAccess(let folder):
            return "Kein Schreibzugriff auf „\(folder)“ – bitte den Ordner einmal freigeben, um dort umzubenennen."
        case .targetExists(let name): return "„\(name)“ gibt es in diesem Ordner schon – nichts wurde umbenannt."
        case .missing(let name): return "„\(name)“ wurde nicht gefunden – nichts wurde umbenannt."
        case .failed(let reason): return "Umbenennen fehlgeschlagen, alte Namen wiederhergestellt: \(reason)"
        case .rollbackIncomplete(let names):
            return "Umbenennen fehlgeschlagen; diese Dateien konnten nicht zurückbenannt werden: \(names.joined(separator: ", "))"
        }
    }
}

extension Organize {
    /// Führt einen `renamePlan` in `dir` aus (nur Einträge ohne Problem und mit neuem Namen); Ergebnis: alt → neu.
    /// Zweistufig über Zwischennamen (Tausch a→b, b→a klappt), überschreibt nie, rollt bei Fehler alles zurück.
    /// Sandbox: braucht Schreibrecht auf `dir` (E8, Ordner-Lesezeichen); der Aufrufer öffnet dessen Zugriff.
    /// `move` nur für Tests (Fehler mitten im Lauf erzwingen).
    static func applyRenames(_ plan: [RenameStep], in dir: URL,
                             folderAccess: FolderAccessStore = .shared,
                             move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> [URL: URL] {
        try folderAccess.withAccess(to: dir) { _ in
            let fm = FileManager.default
            let steps = plan.filter { $0.problem == nil && $0.old != $0.new }
            guard !steps.isEmpty else { return [:] }
            guard fm.isWritableFile(atPath: dir.path) else { throw RenameError.noWriteAccess(folder: dir.lastPathComponent) }
            // Ziele, die selbst umbenannt werden, sind frei; jedes andere vorhandene Ziel ist fremd. (APFS: Groß/klein egal.)
            let olds = Set(steps.map { $0.old.lowercased() })
            for s in steps {
                guard fm.fileExists(atPath: dir.appendingPathComponent(s.old).path) else { throw RenameError.missing(s.old) }
                if !olds.contains(s.new.lowercased()), fm.fileExists(atPath: dir.appendingPathComponent(s.new).path) {
                    throw RenameError.targetExists(s.new)
                }
            }
            let token = UUID().uuidString.prefix(8)
            let pairs = steps.enumerated().map { i, s in
                (old: dir.appendingPathComponent(s.old), tmp: dir.appendingPathComponent(".dropshelf-rename-\(token)-\(i)"),
                 new: dir.appendingPathComponent(s.new))
            }
            var done: [(from: URL, to: URL)] = []
            do {
                for p in pairs { try move(p.old, p.tmp); done.append((p.old, p.tmp)) }
                for p in pairs { try move(p.tmp, p.new); done.append((p.tmp, p.new)) }
            } catch {
                var stuck: [String] = []
                for m in done.reversed() {
                    do { try fm.moveItem(at: m.to, to: m.from) } catch { stuck.append(m.to.lastPathComponent) }
                }
                if !stuck.isEmpty { throw RenameError.rollbackIncomplete(stuck) }
                switch error {
                case CocoaError.fileWriteNoPermission: throw RenameError.noWriteAccess(folder: dir.lastPathComponent)
                default: throw RenameError.failed(error.localizedDescription)
                }
            }
            return Dictionary(uniqueKeysWithValues: pairs.map { ($0.old, $0.new) })
        }
    }

    /// Umbenennen plus Ablage nachziehen (gleiche Position/ID, neues Lesezeichen). Ohne UI.
    @MainActor @discardableResult static func renameItems(_ plan: [RenameStep], in dir: URL, shelf: Shelf,
                                                          folderAccess: FolderAccessStore = .shared) throws -> [URL: URL] {
        let map = try applyRenames(plan, in: dir, folderAccess: folderAccess)
        shelf.replaceURLs(map)
        return map
    }
}
