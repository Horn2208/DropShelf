import AppKit
import SwiftUI

/// Animations-Schalter: System „Bewegung reduzieren“ + eigene Einstellung (`animationsEnabled`).
/// Federn zentral: `.smooth`/`.snappy`/`.bouncy` ab macOS 14, davor `.spring(response:dampingFraction:)`.
enum Motion {
    static var userOn: Bool { UserDefaults.standard.object(forKey: "animationsEnabled") as? Bool ?? true }
    static var enabled: Bool { userOn && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Bei reduzierter Bewegung nur Fade, ohne Animationen gar nichts.
    private static var reduced: Animation? { userOn ? .easeOut(duration: 0.15) : nil }

    /// Pop beim Öffnen und Ablegen.
    static var pop: Animation? {
        guard enabled else { return reduced }
        if #available(macOS 14, *) { return .bouncy(duration: 0.32, extraBounce: 0.06) }
        return .spring(response: 0.32, dampingFraction: 0.7)
    }
    static var smooth: Animation? {
        guard enabled else { return reduced }
        if #available(macOS 14, *) { return .smooth }
        return .spring(response: 0.5, dampingFraction: 1)
    }
    static var snappy: Animation? {
        guard enabled else { return reduced }
        if #available(macOS 14, *) { return .snappy }
        return .spring(response: 0.3, dampingFraction: 0.85)
    }
    static var bouncy: Animation? {
        guard enabled else { return reduced }
        if #available(macOS 14, *) { return .bouncy }
        return .spring(response: 0.5, dampingFraction: 0.7)
    }
    static func scale(_ from: CGFloat, on: Bool) -> CGFloat { enabled && !on ? from : 1 }
}

/// Fenster-Glas: ab macOS 26 echtes Liquid Glass (`NSGlassEffectView`), davor Effekt-View.
@MainActor
enum GlassKit {
    static var liquid: Bool { if #available(macOS 26, *) { true } else { false } }

    /// Zahl aus den Einstellungen (auch als Startargument `-key 0.5`, das als Text ankommt).
    private static func num(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key)
    }

    /// Tönung aus der Einstellung „Glas-Intensität“.
    private static var tintAlpha: CGFloat { 0.02 + 0.3 * num("glassIntensity", 0.25) }

    static func wrap(_ content: NSView, radius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = radius
            g.contentView = content
            retint(g)
            return g
        }
        let fx = NSVisualEffectView()
        fx.material = .underWindowBackground
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = radius
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        content.frame = fx.bounds
        content.autoresizingMask = [.width, .height]
        fx.addSubview(content)
        return fx
    }

    /// Tönung und Lichtbrechung nachziehen, wenn die Regler bewegt werden oder sich die Größe ändert.
    static func retint(_ view: NSView?) {
        if #available(macOS 26, *), let g = view as? NSGlassEffectView {
            let a = tintAlpha
            let dark = NSColor.black.withAlphaComponent(a), light = NSColor.white.withAlphaComponent(a)
            g.tintColor = NSColor(name: nil) { (ap: NSAppearance) -> NSColor in
                ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
            if let root = g.layer { refract(root) }
        }
    }

    /// Lichtbrechung wie bei Canopy 2: Dessen Glas nutzt denselben privaten `glassBackground`-Filter (auf dem
    /// `CABackdropLayer` des System-Glases); die Werte stammen aus Canopys Binary (Faktor `refraction`/`refractionReach`):
    /// innen −40·r / 20·r·w, außen 8·r / 6,25·r·w, Distanz −1/−0,5, Deckkraft 1, Farbsaum 7, kein Blur, Fläche ungetönt.
    /// Hier r = 0,6…2,5 („Lichtbrechung am Rand“) und w = 0,7…1,4 („Reichweite“); „Glas-Intensität“ steuert Klarheit
    /// (MaxLuma) und Blur. Nur die größte Glasfläche (das Fenster), nicht Glas-Knöpfe. Aus = gemerkte Systemwerte.
    /// Filterwerte wirken erst, wenn `filters` neu zugewiesen wird. Fehlt der Filter (andere macOS-Version), passiert nichts.
    private static func refract(_ root: CALayer) {
        guard let l = glassLayers(root).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }
        let d = UserDefaults.standard, k = "filters.glassBackground."
        let keys = ["inputInnerRefractionAmount", "inputInnerRefractionHeight", "inputOuterRefractionAmount", "inputOuterRefractionHeight",
                    "inputRefractionDistance0", "inputRefractionDistance1", "inputRefractionOpacity", "inputAberrationAmount",
                    "inputAberrationHeight", "inputBlurRadius", "inputFaceColorMatrixBlack", "inputFaceColorMatrixWhite",
                    "inputFaceColorMatrixSaturation", "inputFaceColorMatrixMaxLuma", "inputFaceColorMatrixMaxLumaSDR"]
        // Systemwerte einmal pro Ebene merken (an der Ebene selbst), damit „aus“ exakt zurückstellt.
        let orig = l.value(forKey: "dsGlassOrig") as? [String: Any] ?? {
            let o = Dictionary(uniqueKeysWithValues: keys.map { ($0, l.value(forKeyPath: k + $0) ?? 0) })
            l.setValue(o, forKey: "dsGlassOrig")
            return o
        }()
        var v: [String: Any] = orig
        if d.object(forKey: "liquidRefraction") == nil || d.bool(forKey: "liquidRefraction") {
            let r = 0.6 + 1.9 * num("refractionStrength", 0.6)
            let w = 0.7 + 0.7 * num("refractionReach", 0.5)
            let glass = num("glassIntensity", 0.25)
            v = ["inputInnerRefractionAmount": -40 * r, "inputInnerRefractionHeight": 20 * r * w,
                 "inputOuterRefractionAmount": 8 * r, "inputOuterRefractionHeight": 6.25 * r * w,
                 "inputRefractionDistance0": -1, "inputRefractionDistance1": -0.5, "inputRefractionOpacity": 1,
                 "inputAberrationAmount": 6 * r, "inputAberrationHeight": 20 * r * w, "inputBlurRadius": 4 * glass,
                 "inputFaceColorMatrixBlack": 0, "inputFaceColorMatrixWhite": 1, "inputFaceColorMatrixSaturation": 1,
                 "inputFaceColorMatrixMaxLuma": 1 - 0.55 * glass, "inputFaceColorMatrixMaxLumaSDR": 1 - 0.55 * glass]
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, val) in v { l.setValue(val, forKeyPath: k + key) }
        l.filters = l.filters  // sonst übernimmt der Renderer die geänderten Werte nicht
        CATransaction.commit()
    }

    private static func glassLayers(_ l: CALayer) -> [CALayer] {
        let own = l.filters?.contains { ($0 as AnyObject).value(forKey: "name") as? String == "glassBackground" } == true
        return (own ? [l] : []) + (l.sublayers ?? []).flatMap(glassLayers)
    }
}

/// Fallback vor macOS 26: Material + feine Kontur.
private struct MaterialBG<S: InsettableShape>: ViewModifier {
    let shape: S
    let line: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12), lineWidth: line))
    }
}

/// Lässt Glas-Elemente ab macOS 26 ineinanderfließen.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

extension View {
    /// Glas-Hintergrund: Liquid Glass ab macOS 26, sonst Material + feine Kontur.
    @ViewBuilder func glassBG<S: InsettableShape>(_ shape: S, line: CGFloat = 1) -> some View {
        if #available(macOS 26, *) { glassEffect(.regular.interactive(), in: shape) } else { modifier(MaterialBG(shape: shape, line: line)) }
    }

    /// Leiser Schatten, damit Symbole und Text auf klarem Glas über hellem Hintergrund lesbar bleiben.
    func legible() -> some View { shadow(color: .black.opacity(0.5), radius: 2, y: 0.5) }

    /// Pop beim Öffnen (0,85 → 1) und Schließen (1 → 0,9) mit Deckkraft, Mitte als Anker.
    /// Animiert wird von außen über `withAnimation(Motion.pop)` (`ShelfPanel.popIn()`/`animateOut(_:)`).
    /// Bewusst ohne Shader: Layer-Effekte rastern den Inhalt, AppKit-Views (DragOut, Menü) und vibrante Texte verschwinden dann.
    func popScale(shown: Bool, closing: Bool) -> some View {
        scaleEffect(Motion.enabled && !shown ? (closing ? 0.9 : 0.85) : 1, anchor: .center).opacity(shown ? 1 : 0)
    }

    /// Symbol hüpft, wenn sich `value` ändert (macOS 14+, nicht bei reduzierter Bewegung).
    @ViewBuilder func bounceSymbol<V: Equatable>(_ value: V) -> some View {
        if #available(macOS 14, *), Motion.enabled { symbolEffect(.bounce, value: value) } else { self }
    }
}

/// Runder Glas-Knopf, Hover leicht größer (ab macOS 26 übernimmt das Glas selbst).
struct GlassCircleButton: View {
    let symbol: String
    var size: CGFloat = 28
    var help: String = ""
    var action: () -> Void = {}
    @State private var hover = false

    var body: some View {
        Button(action: action) { GlassCircleLabel(symbol: symbol, size: size) }
            .buttonStyle(.plain)
            .scaleEffect(hover && Motion.enabled && !GlassKit.liquid ? 1.06 : 1)
            .animation(Motion.snappy, value: hover)
            .onHover { hover = $0 }
            .help(help)
    }
}

struct GlassCircleLabel: View {
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.85))
            .legible()
            .frame(width: size, height: size)
            .glassBG(Circle())
    }
}
