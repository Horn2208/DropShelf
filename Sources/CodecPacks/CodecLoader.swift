import Foundation

enum CodecError: LocalizedError {
    case loadFailed(String), symbolMissing(String), apiMismatch(found: Int, expected: Int)
    var errorDescription: String? {
        switch self {
        case .loadFailed(let m): return "Der Codec konnte nicht geladen werden: \(m)"
        case .symbolMissing(let s): return "Dem Codec fehlt die Funktion „\(s)“."
        case .apiMismatch(let f, let e): return "Der Codec passt nicht zur App (Version \(f), erwartet \(e)). Bitte neu laden."
        }
    }
}

final class CodecHandle: @unchecked Sendable {
    let id: String
    private let handle: UnsafeMutableRawPointer
    fileprivate init(id: String, handle: UnsafeMutableRawPointer) { self.id = id; self.handle = handle }

    /// `T` muss ein `@convention(c)`-Funktionstyp sein.
    func symbol<T>(_ name: String, as: T.Type) throws -> T {
        guard let p = dlsym(handle, name) else { throw CodecError.symbolMissing(name) }
        return unsafeBitCast(p, to: T.self)
    }

    fileprivate func close() { dlclose(handle) }
}

enum CodecLoader {
    /// ponytail: kein dlclose bei Erfolg, die Dylib bleibt bis App-Ende geladen; reicht, Updates greifen nach Neustart.
    static func load(_ url: URL, expectedAPI: Int) throws -> CodecHandle {
        guard let h = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw CodecError.loadFailed(dlerror().map { String(cString: $0) } ?? "unbekannt")
        }
        let handle = CodecHandle(id: url.deletingPathExtension().lastPathComponent, handle: h)
        do {
            let found = Int(try handle.symbol(CodecABI.apiVersionSymbol, as: CodecABI.APIVersion.self)())
            guard found == expectedAPI else { throw CodecError.apiMismatch(found: found, expected: expectedAPI) }
        } catch {
            handle.close()
            throw error
        }
        return handle
    }
}
