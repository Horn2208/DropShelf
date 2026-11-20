import AppKit
import SwiftUI

/// Animations-Schalter: System „Bewegung reduzieren“ + eigene Einstellung (`animationsEnabled`).
/// Federn zentral: `.smooth`/`.snappy`/`.bouncy` ab macOS 14, davor `.spring(response:dampingFraction:)`.
enum Motion {
    static var userOn: Bool { UserDefaults.standard.object(forKey: "animationsEnabled") as? Bool ?? true }
    static var enabled: Bool { userOn && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Bei reduzierter Bewegung nur Fade, ohne Animationen gar nichts.
    private static var reduced: Animation? { userOn ? .easeOut(duration: 0.15) : nil }

    /// Kurven/Dauern (UX-Motion-Regeln): Öffnen/Aufklappen Ease-out ~0,24 s, Schließen/Zuklappen Ease-in in ½ der Zeit.
    enum Curve {
        static let expand = 0.24, collapse = 0.12
        static var enter: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) }
        static var exit: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.7, 0, 0.84, 0) }
    }

    /// Pop beim Öffnen und Ablegen: Feder mit wenig Überschwingen, ~0,25 s (öffnet oft am Tag → kaum Schnörkel).
    static var pop: Animation? {
        guard enabled else { return reduced }
        if #available(macOS 14, *) { return .bouncy(duration: 0.25, extraBounce: 0.04) }
        return .spring(response: 0.25, dampingFraction: 0.75)
    }
    /// Schließen/Zuklappen: Ease-in, halb so lang wie das Öffnen.
    static var close: Animation? {
        guard enabled else { return reduced }
        return .timingCurve(0.7, 0, 0.84, 0, duration: Curve.collapse)
    }
    static var smooth: Animation? {
        guard enabled else { return reduced }
        if #available(macOS 14, *) { return .smooth(duration: 0.3) }
        return .spring(response: 0.3, dampingFraction: 1)
    }
    /// Hover-/Druck-Rückmeldung: 0,15 s.
    static var snappy: Animation? {
        guard enabled else { return reduced }
        if #available(macOS 14, *) { return .snappy(duration: 0.15) }
        return .spring(response: 0.15, dampingFraction: 0.85)
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
    /// Ohne `NSGlassEffectView` (Aktionsleiste: nur SwiftUI-Glas-Knöpfe) werden nur Klarheit/Blur angeglichen.
    static func retint(_ view: NSView?) {
        guard #available(macOS 26, *), let view else { return }
        if let g = view as? NSGlassEffectView {
            let a = tintAlpha
            let dark = NSColor.black.withAlphaComponent(a), light = NSColor.white.withAlphaComponent(a)
            g.tintColor = NSColor(name: nil) { (ap: NSAppearance) -> NSColor in
                ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        }
        if let root = view.layer { refract(root, window: view is NSGlassEffectView) }
    }

    /// Wie `retint`, aber erst im nächsten Durchlauf: SwiftUI legt neue Glas-Ebenen (Knöpfe, Kapsel) erst beim Rendern an.
    static func retintSoon(_ view: NSView?) {
        DispatchQueue.main.async { [weak view] in retint(view) }
    }

    /// Lichtbrechung wie bei Canopy 2: Dessen Glas nutzt denselben privaten `glassBackground`-Filter (auf dem
    /// `CABackdropLayer` des System-Glases); die Werte stammen aus Canopys Binary (Faktor `refraction`/`refractionReach`):
    /// innen −40·r / 20·r·w, außen 8·r / 6,25·r·w, Distanz −1/−0,5, Deckkraft 1, Farbsaum 7, kein Blur, Fläche ungetönt.
    /// Hier r = 0,6…2,5 („Lichtbrechung am Rand“) und w = 0,7…1,4 („Reichweite“); „Glas-Intensität“ steuert Klarheit
    /// (MaxLuma) und Blur. Volle Linse nur auf der größten Glasfläche (dem Fenster); Glas-Knöpfe bekommen nur dieselbe
    /// Klarheit. Aus = gemerkte Systemwerte.
    /// Filterwerte wirken erst, wenn `filters` neu zugewiesen wird. Fehlt der Filter (andere macOS-Version), passiert nichts.
    private static func refract(_ root: CALayer, window: Bool) {
        let layers = glassLayers(root)
        guard !layers.isEmpty else { return }
        let big = window ? layers.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height } : nil
        let d = UserDefaults.standard, k = "filters.glassBackground."
        let on = d.object(forKey: "liquidRefraction") == nil || d.bool(forKey: "liquidRefraction")
        let r = 0.6 + 1.9 * num("refractionStrength", 0.6)
        let w = 0.7 + 0.7 * num("refractionReach", 0.5)
        let glass = num("glassIntensity", 0.25)
        let clarity: [String: Any] = ["inputBlurRadius": 4 * glass, "inputFaceColorMatrixBlack": 0, "inputFaceColorMatrixWhite": 1,
                                      "inputFaceColorMatrixSaturation": 1, "inputFaceColorMatrixMaxLuma": 1 - 0.55 * glass,
                                      "inputFaceColorMatrixMaxLumaSDR": 1 - 0.55 * glass]
        let lens: [String: Any] = ["inputInnerRefractionAmount": -40 * r, "inputInnerRefractionHeight": 20 * r * w,
                                   "inputOuterRefractionAmount": 8 * r, "inputOuterRefractionHeight": 6.25 * r * w,
                                   "inputRefractionDistance0": -1, "inputRefractionDistance1": -0.5, "inputRefractionOpacity": 1,
                                   "inputAberrationAmount": 6 * r, "inputAberrationHeight": 20 * r * w]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in layers {
            // Systemwerte einmal pro Ebene merken (an der Ebene selbst), damit „aus“ exakt zurückstellt.
            let orig = l.value(forKey: "dsGlassOrig") as? [String: Any] ?? {
                let o = Dictionary(uniqueKeysWithValues: (Array(lens.keys) + Array(clarity.keys)).map { ($0, l.value(forKeyPath: k + $0) ?? 0) })
                l.setValue(o, forKey: "dsGlassOrig")
                return o
            }()
            // Fenster: volle Linse; Glas-Knöpfe/Kapsel: System-Linse (passt zur kleinen Form), aber gleich klar statt milchig.
            let v = !on ? orig : orig.merging(l === big ? lens.merging(clarity) { $1 } : clarity) { $1 }
            l.setValue(on ? v : nil, forKey: Self.valuesKey)
            if on { BackdropPatch.install(on: l) }
            // Nur schreiben, wenn sich etwas ändert: `filters` neu zuweisen zwingt den Renderer zum Neuaufbau.
            guard v.contains(where: { (l.value(forKeyPath: k + $0.key) as? NSNumber) != ($0.value as? NSNumber) }) else { continue }
            for (key, val) in v { l.setValue(val, forKeyPath: k + key) }
            l.filters = l.filters  // sonst übernimmt der Renderer die geänderten Werte nicht
        }
        CATransaction.commit()
    }

    nonisolated static let valuesKey = "dsGlassValues"

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
        Image.symbol(symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.85))
            .legible()
            .frame(width: size, height: size)
            .glassBG(Circle())
    }
}

extension Image {
    /// SF Symbol per Name. „airdrop“ liegt nur im privaten Symbolkatalog (CoreGlyphsPrivate) – dann über
    /// `+[NSImage imageWithPrivateSystemSymbolName:]` (Vorlagenbild, folgt Schrift/Farbe wie ein normales Symbol);
    /// fehlt auch das (andere macOS-Version), das bisherige Funkwellen-Symbol.
    static func symbol(_ name: String) -> Image {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return Image(systemName: name) }
        if let img = NSImage.privateSymbol(name) { return Image(nsImage: img).renderingMode(.template) }
        return Image(systemName: "dot.radiowaves.up.forward")
    }
}

extension NSImage {
    static func privateSymbol(_ name: String) -> NSImage? {
        let sel = NSSelectorFromString("imageWithPrivateSystemSymbolName:")
        guard NSImage.responds(to: sel) else { return nil }
        return (NSImage.self as AnyObject).perform(sel, with: name)?.takeUnretainedValue() as? NSImage
    }
}

/// Hält die Glaswerte fest: Das System ersetzt das `filters`-Array des `CABackdropLayer` bei jedem Zustandswechsel
/// (Fenster wird Schlüssel/aktiv, App-Wechsel, Drag über dem Fenster, SwiftUI-Glas-Animation) durch frische Filter mit
/// seinen Standardwerten – nach unseren Benachrichtigungen, also kein verlässlicher Zeitpunkt zum Nachziehen.
/// Daher bekommt jede gefundene Glas-Ebene eine Laufzeit-Unterklasse, deren `setFilters:` unsere Werte (an der Ebene
/// unter `GlassKit.valuesKey`) in den neuen `glassBackground`-Filter schreibt, bevor er übernommen wird. Kostet nur dann
/// etwas, wenn das System ohnehin neu filtert. Fehlt die Klasse/der Selektor (andere macOS-Version), bleibt alles beim Alten.
enum BackdropPatch {
    private nonisolated(unsafe) static var subclass: AnyClass?
    private nonisolated(unsafe) static var tried = false

    @MainActor static func install(on layer: CALayer) {
        guard let base = NSClassFromString("CABackdropLayer"), object_getClass(layer) == base else { return }
        if !tried { tried = true; subclass = makeSubclass(of: base) }
        if let subclass { object_setClass(layer, subclass) }
    }

    #if DEBUG
    /// Ohne UI: Ein frischer `glassBackground`-Filter (wie ihn das System bei Zustandswechseln setzt) bekommt unsere Werte.
    @MainActor static func selfCheck() {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return }
        let make = { () -> NSObject? in
            let f = (filterClass as AnyObject).perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
            f?.setValue("glassBackground", forKey: "name")
            return f
        }
        let l = cls.init()
        l.setValue(["inputRadius": 3.5], forKey: GlassKit.valuesKey)
        install(on: l)
        guard let f = make() else { return }
        f.setValue(9.0, forKey: "inputRadius")
        l.filters = [f]  // System-Neuaufbau nachgestellt
        let v = l.value(forKeyPath: "filters.glassBackground.inputRadius") as? Double
        assert(object_getClass(l) != cls && v == 3.5, "BackdropPatch: \(String(describing: v))")
        NSLog("GLASS-SELFCHECK ok radius=%@", String(describing: v))
    }
    #endif

    private static func makeSubclass(of base: AnyClass) -> AnyClass? {
        let sel = NSSelectorFromString("setFilters:")
        guard let method = class_getInstanceMethod(base, sel),
              let sub = objc_allocateClassPair(base, "DSRefractBackdropLayer", 0) else { return nil }
        typealias Setter = @convention(c) (AnyObject, Selector, NSArray?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let block: @convention(block) (CALayer, NSArray?) -> Void = { layer, filters in
            if let values = layer.value(forKey: GlassKit.valuesKey) as? [String: Any] {
                for case let f as NSObject in filters ?? [] where f.value(forKey: "name") as? String == "glassBackground" {
                    for (key, val) in values { f.setValue(val, forKey: key) }
                }
            }
            original(layer, sel, filters)
        }
        class_addMethod(sub, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        objc_registerClassPair(sub)
        return sub
    }
}
