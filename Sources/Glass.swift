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

/// Flüssiges Einsaugen (`progress` 0 = normal, 1 = weg): ab macOS 14 Genie-Shader + RGB-Versatz (`Shaders.metal`),
/// sonst bzw. bei reduzierter Bewegung das bisherige Skalieren auf `fallbackScale`. Animierbar über `Motion.pop`.
/// Nur für reine SwiftUI-Inhalte (Vorschaubilder): Shader-Effekte rastern immer, auch mit `isEnabled: false`.
struct LiquidWarp: ViewModifier, Animatable {
    var progress: CGFloat
    var fallbackScale: CGFloat = 0.85
    var target = UnitPoint.top
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    @State private var size = CGSize(width: 1, height: 1)

    func body(content: Content) -> some View {
        let p = progress, fade = 1 - min(max(p, 0), 1) * min(max(p, 0), 1)
        if #available(macOS 14, *), Motion.enabled {
            let on = abs(p) > 0.002, pt = CGPoint(x: size.width * target.x, y: size.height * target.y)
            content
                .distortionEffect(ShaderLibrary.liquidGenie(.float2(size), .float2(pt), .float(Float(p))),
                                  maxSampleOffset: .zero, isEnabled: on)
                .layerEffect(ShaderLibrary.liquidAberration(.float2(pt), .float(Float(min(max(p, 0), 1) * 3))),
                             maxSampleOffset: CGSize(width: 3, height: 3), isEnabled: on)
                .opacity(fade)
                .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { size = $0 } })
        } else {
            content.scaleEffect(Motion.enabled ? 1 - (1 - fallbackScale) * p : 1, anchor: .center).opacity(1 - p)
        }
    }
}

extension AnyTransition {
    /// Einfliegen/Herausziehen einzelner Vorschaubilder mit dem Flüssig-Effekt.
    static var liquid: AnyTransition {
        .modifier(active: LiquidWarp(progress: 1, fallbackScale: 0.6), identity: LiquidWarp(progress: 0, fallbackScale: 0.6))
    }
}

/// Fenster-Glas: ab macOS 26 echtes Liquid Glass (`NSGlassEffectView`), davor Effekt-View.
@MainActor
enum GlassKit {
    static var liquid: Bool { if #available(macOS 26, *) { true } else { false } }

    /// Tönung aus der Einstellung „Glas-Intensität“.
    private static var tintAlpha: CGFloat { 0.02 + 0.3 * CGFloat(UserDefaults.standard.object(forKey: "glassIntensity") as? Double ?? 0.4) }

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

    /// Tönung nachziehen, wenn der Regler bewegt wird.
    static func retint(_ view: NSView?) {
        if #available(macOS 26, *), let g = view as? NSGlassEffectView {
            let a = tintAlpha
            let dark = NSColor.black.withAlphaComponent(a), light = NSColor.white.withAlphaComponent(a)
            g.tintColor = NSColor(name: nil) { (ap: NSAppearance) -> NSColor in
                ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        }
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
            .frame(width: size, height: size)
            .glassBG(Circle())
    }
}
