import Foundation

/// C-Schnittstelle jeder Codec-Dylib. Änderungen erhöhen `dsc_api_version()`.
enum CodecABI {
    static let apiVersionSymbol = "dsc_api_version"
    static let convertSymbol = "dsc_convert"

    typealias APIVersion = @convention(c) () -> Int32
    /// (Quelle, Ziel, Zielendung) → 0 bei Erfolg.
    typealias Convert = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
}
