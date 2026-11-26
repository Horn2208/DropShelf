import Foundation

/// Fassade für statisch eingebundene, quelloffene Encoder-Bibliotheken.
public enum DropShelfCodecs {
    public static let version = "0.4.0"

    /// Namen der in diesem Build statisch verfügbaren Encoder-Module.
    public static var availableEncoders: [String] {
        ["ogg-vorbis", "ogg-opus", "flac", "mp3", "webp", "wavpack"]
    }
}
