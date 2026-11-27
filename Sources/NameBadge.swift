import SwiftUI
import AppKit

/// Ausweiskarte an einem Band. Echtes Pendel (pro Frame integriert), Karte lässt sich greifen, ziehen und loslassen;
/// Klick dreht sie um die vertikale Achse (Vorder-/Rückseite).
struct NameBadge: View {
    static let nameKey = "userDisplayName"

    // MARK: Stellschrauben
    private enum Tune {
        static let gravity = 7.0         // k = g/L in 1/s² (Eigenfrequenz ≈ √k ≈ 2.6 rad/s)
        static let damping = 1.5         // c in 1/s (Dämpfung der Winkelgeschwindigkeit)
        static let maxDt = 1.0 / 30      // Zeitschritt-Begrenzung (s)
        static let maxAngle = 0.95       // Auslenkung beim Ziehen (rad, ≈ 54°)
        static let maxStretch = 22.0     // maximale Banddehnung (pt)
        static let stretchDecay = 9.0    // Rückfederrate der Dehnung (1/s)
        static let maxOmega = 14.0       // Begrenzung der Wurfgeschwindigkeit (rad/s)
        static let releaseGrace = 0.08   // Stand die Maus länger still, wirft sie nicht (s)
        static let dragThreshold = 4.0   // Mindeststrecke Ziehen vs. Klick (pt)
        static let appearKick = 1.8      // Anschwung beim Erscheinen (rad/s)
        static let tapKick = 1.2         // Anstoß beim Klick (rad/s)
        static let settle = 0.0008       // Ruheschwelle
    }
    private static let strapLen = 40.0, clipH = 12.0, cardW = 160.0, cardH = 230.0
    private static let restCenter = strapLen + clipH + cardH / 2   // Abstand Ankerpunkt → Kartenmitte
    private static let frameW = 300.0, frameH = 330.0

    @AppStorage(NameBadge.nameKey) private var name = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = Pendulum()
    @State private var spin = 0.0
    @State private var paused = false
    @State private var grabbed = false
    @State private var offset = CGSize.zero   // nur „Bewegung reduzieren“

    @MainActor final class Pendulum {
        var theta = 0.0, omega = 0.0, extra = 0.0
        var last: Date?, dragging = false, lastEvent = Date.distantPast
        var settled = false

        func step(_ now: Date) {
            defer { last = now }
            guard let last, !dragging else { return }
            let dt = min(max(now.timeIntervalSince(last), 0), Tune.maxDt)
            omega += (-Tune.gravity * sin(theta) - Tune.damping * omega) * dt   // semi-implizit: erst ω, dann θ
            theta += omega * dt
            extra *= exp(-Tune.stretchDecay * dt)
            if abs(theta) < Tune.settle, abs(omega) < Tune.settle, extra < 0.05 { theta = 0; omega = 0; extra = 0; settled = true }
        }
    }

    // MARK: Body
    var body: some View {
        TimelineView(.animation(paused: reduceMotion ? !grabbed && offset == .zero : paused)) { ctx in
            frame(ctx.date)
        }
        .frame(width: Self.frameW, height: Self.frameH, alignment: .top)
        .contentShape(Rectangle())
        .gesture(drag)
        .onAppear {
            guard !reduceMotion else { return }
            wake(); model.omega = Tune.appearKick
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ausweiskarte: \(shown)")
    }

    private func frame(_ now: Date) -> some View {
        if !reduceMotion {
            model.step(now)
            if model.settled && !paused { DispatchQueue.main.async { paused = true } }
        }
        return hanging(theta: reduceMotion ? 0 : model.theta, extra: reduceMotion ? 0 : model.extra)
            .offset(reduceMotion ? offset : .zero)
    }

    private func hanging(theta: Double, extra: Double) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 10, height: Self.strapLen + extra)
                .overlay(alignment: .bottom) {   // Band läuft nach oben aus dem Bild
                    Rectangle().fill(NordicCobalt.metalGradient).frame(width: 10, height: 600)
                        .overlay(Color.black.opacity(0.18))
                }
            clip.zIndex(1).padding(.bottom, -6)
            Flip(angle: spin, front: front(shine: theta), back: back)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                .frame(width: Self.cardW, height: Self.cardH)
                .onTapGesture { flip() }
        }
        .rotationEffect(.radians(theta), anchor: .top)
        .frame(width: Self.frameW, alignment: .top)
    }

    // MARK: Ziehen
    private var drag: some Gesture {
        DragGesture(minimumDistance: Tune.dragThreshold, coordinateSpace: .local)
            .onChanged { v in
                if !grabbed {
                    guard onCard(v.startLocation) else { return }
                    grabbed = true; wake(); model.dragging = true
                }
                guard grabbed else { return }
                if reduceMotion { offset = v.translation; return }
                let vx = v.translation.width, vy = Self.restCenter + v.translation.height
                let target = min(max(atan2(-vx, vy), -Tune.maxAngle), Tune.maxAngle)
                let over = max(0, hypot(vx, vy) - Self.restCenter)
                let now = Date(), dt = now.timeIntervalSince(model.lastEvent)
                if dt > 0.001, dt < 0.2 {
                    model.omega = 0.5 * model.omega + 0.5 * (target - model.theta) / dt
                }
                model.lastEvent = now
                model.theta = target
                model.extra = Tune.maxStretch * (1 - exp(-over / Tune.maxStretch))
            }
            .onEnded { _ in
                guard grabbed else { return }
                grabbed = false
                if reduceMotion { offset = .zero; return }   // springt ohne Schwingen zurück
                model.dragging = false
                if Date().timeIntervalSince(model.lastEvent) > Tune.releaseGrace { model.omega = 0 }
                model.omega = min(max(model.omega, -Tune.maxOmega), Tune.maxOmega)
                model.last = nil
            }
    }

    /// Trefferprüfung der Startposition gegen die (um den Anker gedrehte) Karte.
    private func onCard(_ p: CGPoint) -> Bool {
        let dx = p.x - Self.frameW / 2, dy = p.y
        let th = reduceMotion ? 0 : model.theta
        let u = dx * cos(th) + dy * sin(th)          // zurückdrehen (rotationEffect dreht im Uhrzeigersinn)
        let w = -dx * sin(th) + dy * cos(th)
        return abs(u) <= Self.cardW / 2 && abs(w - Self.restCenter - model.extra) <= Self.cardH / 2
    }

    private func wake() { model.settled = false; model.last = nil; paused = false }

    private func flip() {
        if reduceMotion { spin += 180; return }
        wake(); model.omega += Tune.tapKick
        withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { spin += 180 }
    }

    // MARK: Karte
    private var shown: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "DropShelf" : n
    }
    private var hasName: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var version: String { appVersion }

    private var clip: some View {
        ZStack {
            Capsule().fill(NordicCobalt.metalGradient).frame(width: 30, height: Self.clipH)
            Capsule().fill(Color.black.opacity(0.45)).frame(width: 14, height: 4)   // Öse
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }

    private func front(shine: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ACCESS PASS"); Spacer(); Text("DROPSHELF · V\(version)")
            }
            .font(.system(size: 7, weight: .semibold)).tracking(1.1).foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 7)
            Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5)
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [NordicCobalt.deep, NordicCobalt.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                Waves(phase: 0).stroke(NordicCobalt.highlight.opacity(0.35), lineWidth: 1.2)
                Waves(phase: 1.3).stroke(NordicCobalt.highlight.opacity(0.22), lineWidth: 1)
                Waves(phase: 2.6).stroke(NordicCobalt.highlight.opacity(0.14), lineWidth: 2.4).blur(radius: 1.5)
                Text("ALL ACCESS · MAC").font(.system(size: 7, weight: .bold)).tracking(1.4)
                    .foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 12).padding(.bottom, 7)
            }
            .frame(height: 58).clipped()
            VStack(alignment: .leading, spacing: 0) {
                Text(hasName ? "Hallo" : "Dein Pass für").foregroundStyle(.white)
                Text(hasName ? "\(shown)." : "DropShelf.").foregroundStyle(NordicCobalt.highlight)
            }
            .font(.system(size: 24, weight: .bold)).lineLimit(1).minimumScaleFactor(0.4)
            .padding(.horizontal, 12).padding(.top, 12)
            Spacer(minLength: 6)
            HStack(spacing: 10) {
                infoCell("VERSION", version)
                Rectangle().fill(.white.opacity(0.16)).frame(width: 0.5, height: 24)
                infoCell("PLATTFORM", "macOS")
                Spacer()
            }
            .padding(.horizontal, 12)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5).padding(.top, 8)
            HStack(spacing: 5) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 14, height: 14)
                Text("DropShelf").font(.system(size: 9, weight: .bold))
                Spacer()
                Text("v\(version)").font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: Self.cardW, height: Self.cardH)
        .background(NordicCobalt.deep)
        .overlay {   // sanfter Glanzstreifen, wandert mit der Auslenkung
            LinearGradient(colors: [.clear, .white.opacity(0.16), .clear],
                           startPoint: UnitPoint(x: 0.1 + shine * 0.9, y: 0), endPoint: UnitPoint(x: 0.5 + shine * 0.9, y: 1))
                .blendMode(.plusLighter).allowsHitTesting(false)
        }
    }

    private func infoCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 6, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        }
    }

    private var back: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            Text(shown).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.5)
            Spacer()
            Text("Danke, dass du DropShelf nutzt.").font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.7)).padding(.bottom, 14)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.cardW, height: Self.cardH)
        .background(LinearGradient(colors: [NordicCobalt.deep, NordicCobalt.accent], startPoint: .top, endPoint: .bottom))
    }
}

/// Dreht Vorder- und Rückseite; Rückseite wird gegengedreht, damit sie nicht gespiegelt erscheint.
private struct Flip<F: View, B: View>: View, Animatable {
    var angle: Double
    let front: F, back: B
    nonisolated var animatableData: Double { get { angle } set { angle = newValue } }
    var body: some View {
        ZStack {
            if cos(angle * .pi / 180) < 0 { back.rotation3DEffect(.degrees(180), axis: (0, 1, 0)) } else { front }
        }
        .rotation3DEffect(.degrees(angle), axis: (0, 1, 0), perspective: 0.5)
    }
}

private struct Waves: Shape {
    var phase: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY + sin(phase) * 8
        p.move(to: CGPoint(x: r.minX, y: y))
        p.addCurve(to: CGPoint(x: r.maxX, y: y - 10 + cos(phase) * 8),
                   control1: CGPoint(x: r.width * 0.3, y: y - 28 - phase * 3),
                   control2: CGPoint(x: r.width * 0.65, y: y + 30 + phase * 3))
        return p
    }
}
