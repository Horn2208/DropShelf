import SwiftUI
import AppKit

/// Farb-Tokens des Designs "Nordic Cobalt". Dark/Light folgen dem Erscheinungsbild.
enum NordicCobalt {
    private static func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    private static func dynamic(_ name: String, dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static let accent = Color(nsColor: hex(0x2563EB))
    static let highlight = Color(nsColor: hex(0x38BDF8))
    static let tint = Color(nsColor: hex(0x2563EB, 0.12))

    static let canvas = dynamic("nc.canvas", dark: hex(0x181B20), light: hex(0xF4F3EF))
    static let panel = dynamic("nc.panel", dark: hex(0x1E222A, 0.78), light: hex(0xFFFFFF, 0.82))
    static let card = dynamic("nc.card", dark: hex(0x262B35), light: hex(0xECEAE4))
    static let hairline = dynamic("nc.hairline", dark: hex(0xFFFFFF, 0.10), light: hex(0x181B20, 0.10))
    static let textPrimary = dynamic("nc.text1", dark: hex(0xF8FAFC), light: hex(0x181B20))
    static let textSecondary = dynamic("nc.text2", dark: hex(0x94A3B8), light: hex(0x64748B))

    static let success = Color(nsColor: hex(0x16A34A))
    static let warning = Color(nsColor: hex(0xD97706))
    static let error = Color(nsColor: hex(0xDC2626))
}

// MARK: - Glas-, Metall- und Milchglas-Varianten (nur für Einstellungen und Bearbeitungs-Fenster, nicht für Shelf/Menüs)

extension NordicCobalt {
    /// Tiefes Kobalt-Blau, z.B. als Unterlage für Leuchteffekte.
    static let deep = Color(nsColor: hex(0x0A1233))
    /// Deckende Grundfläche der Bearbeitungs-Fenster: helles Milchgrau bzw. dunkles Schiefer.
    static let milkyBase = dynamic("nc.milky", dark: hex(0x1E222A), light: hex(0xF1F3F7))
    private static let metalHi = Color(nsColor: hex(0xCBD5E1))
    private static let metalLo = Color(nsColor: hex(0x94A3B8))
    static let metalGradient = LinearGradient(colors: [metalHi, metalLo], startPoint: .top, endPoint: .bottom)
}

private struct NordicShimmer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                LinearGradient(colors: [NordicCobalt.accent.opacity(0.08), NordicCobalt.highlight.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(stops: [.init(color: .clear, location: 0.30), .init(color: .white.opacity(0.10), location: 0.45),
                                       .init(color: .clear, location: 0.60)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Gebürstetes Metall: Verlauf #CBD5E1 → #94A3B8 mit feinen waagerechten Linien. Als Hintergrund gedacht.
private struct BrushedMetal: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                NordicCobalt.metalGradient
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    var seed: UInt32 = 7
                    while y < size.height {
                        seed = seed &* 1664525 &+ 1013904223  // feste Zufallsfolge, damit das Muster nicht flackert
                        let a = 0.04 + Double(seed >> 24) / 255 * 0.10
                        var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(p, with: .color(.white.opacity(a)), lineWidth: 0.5)
                        y += 1.5
                    }
                }
            }
            .opacity(scheme == .dark ? 0.28 : 0.55)
            .allowsHitTesting(false)
        }
    }
}

/// Deckender milchiger Hintergrund mit Kobalt-Ton für die Bearbeitungs-Fenster.
private struct MilkyCobalt: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                NordicCobalt.milkyBase
                NordicCobalt.accent.opacity(0.10)
                LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// Dezentes diagonales Glanzband mit Kobalt-Tönung.
    func nordicShimmer() -> some View { modifier(NordicShimmer()) }
    /// Feine gebürstete Metall-Textur als Hintergrund (Akzent, sparsam einsetzen).
    func brushedMetal() -> some View { modifier(BrushedMetal()) }
    /// Deckender, milchiger Bearbeitungs-Hintergrund mit Kobalt-Ton.
    func milkyCobalt() -> some View { modifier(MilkyCobalt()) }
}
