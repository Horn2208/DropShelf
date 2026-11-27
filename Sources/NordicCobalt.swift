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

/// Echtes Hintergrund-Material (verschwommener Desktop dahinter). Braucht ein transparentes Fenster.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Milchglas für die Bearbeitungs-Fenster: Blur, darüber eine helle, leicht kobaltgetönte Schicht mit viel Deckkraft, Lichtkante oben.
private struct MilkyCobalt: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content.background {
            ZStack {
                BehindWindowBlur()
                (dark ? Color.white.opacity(0.16) : Color.white.opacity(0.62))  // Milch
                NordicCobalt.accent.opacity(dark ? 0.10 : 0.06)
                LinearGradient(colors: [.white.opacity(dark ? 0.10 : 0.30), .clear], startPoint: .top, endPoint: .center)
                VStack(spacing: 0) {  // Lichtkante
                    LinearGradient(colors: [.white.opacity(0.0), .white.opacity(dark ? 0.35 : 0.9), .white.opacity(0.0)],
                                   startPoint: .leading, endPoint: .trailing).frame(height: 1)
                    Spacer()
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Bedienleiste ("Armatur") der Bearbeitungsfenster

/// Schwebende Glas-Kapsel mit Lichtkante und Schatten.
private struct GlassCapsule: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.white.opacity(scheme == .dark ? 0.06 : 0.35)))
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.35 : 0.9), .white.opacity(0.08)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            }
    }
}

/// Gemeinsame Optik der Leistenknöpfe: Klick skaliert leicht herunter (nicht bei „Bewegung reduzieren“).
struct BarButtonStyle: ButtonStyle {
    enum Kind { case icon, pill, primary, quiet }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        let label = configuration.label
            .font(.system(size: 12.5, weight: kind == .icon ? .regular : .medium))
            .foregroundStyle(kind == .primary ? Color.white : NordicCobalt.textPrimary)
            .padding(.horizontal, kind == .icon ? 0 : 14)
            .frame(width: kind == .icon ? 30 : nil, height: 30)
        return label
            .background {
                Capsule().fill(fill(dark: dark, pressed: configuration.isPressed))
                    .overlay(Capsule().strokeBorder(kind == .primary ? Color.white.opacity(0.35) : NordicCobalt.hairline, lineWidth: 1))
            }
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hover)
            .onHover { hover = $0 }
            .contentShape(Capsule())
    }

    private func fill(dark: Bool, pressed: Bool) -> AnyShapeStyle {
        if kind == .primary {
            let o = pressed ? 0.85 : (hover && enabled ? 1 : 0.92)
            return AnyShapeStyle(LinearGradient(colors: [NordicCobalt.accent.opacity(o), NordicCobalt.highlight.opacity(o)],
                                                startPoint: .leading, endPoint: .trailing))
        }
        let base = dark ? 0.10 : 0.45
        let boost = pressed ? 0.18 : (hover && enabled ? 0.12 : 0)
        return AnyShapeStyle(Color.white.opacity(base + boost))
    }
}

/// Dünne senkrechte Trennlinie zwischen Werkzeugen und Aktionen.
struct BarDivider: View {
    var body: some View { Rectangle().fill(NordicCobalt.hairline).frame(width: 1, height: 20).padding(.horizontal, 4) }
}

extension View {
    /// Dezentes diagonales Glanzband mit Kobalt-Tönung.
    func nordicShimmer() -> some View { modifier(NordicShimmer()) }
    /// Feine gebürstete Metall-Textur als Hintergrund (Akzent, sparsam einsetzen).
    func brushedMetal() -> some View { modifier(BrushedMetal()) }
    /// Milchglas-Hintergrund (Blur + helle Milchschicht) mit Kobalt-Ton.
    func milkyCobalt() -> some View { modifier(MilkyCobalt()) }
    /// Schwebende Glas-Kapsel für die Bedienleiste.
    func glassCapsule() -> some View { modifier(GlassCapsule()) }
}
