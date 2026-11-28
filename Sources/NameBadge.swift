import SwiftUI
import AppKit
import simd

/// Ausweiskarte an einem Band. Das Band ist eine Verlet-Seilkette mit Längen- und Biegebedingungen, die Karte hängt
/// als schwerer Punkt am Seilende. Karte und Band lassen sich greifen, ziehen und werfen; Klick dreht die Karte
/// (Vorder-/Rückseite), die Maus neigt sie, weit nach rechts gezogen dreht sie sich einmal um 360°.
struct NameBadge: View {
    static let nameKey = "userDisplayName"

    // MARK: Stellschrauben (Weltmaßstab: 1 Einheit = Kartenbreite = `unit` pt, y nach unten)
    private enum Tune {
        static let unit = 160.0              // pt pro Einheit
        static let segments = 18             // Seilsegmente (19 Seilpunkte, Punkt 0 = Anker)
        static let ropeLength = 1.4318 * unit    // Ruhelänge des Bands (pt)
        static let attach = 0.9182 * unit    // Seilende → Kartenmitte (Klammer + Schlitz, pt)
        static let gravity = 26.0 * unit     // pt/s²
        static let dt = 1.0 / 120            // fester Physik-Zeitschritt (s)
        static let maxFrame = 0.05           // längster Frame, der nachgerechnet wird (s)
        static let damping = 0.986           // Verlet-Geschwindigkeitsfaktor pro Schritt
        static let cardDamping = 0.982       // zusätzlich für die Karte
        static let iterations = 20           // Bedingungs-Iterationen pro Schritt
        static let ropeInvMass = 1.0, cardInvMass = 0.12
        static let bendMin = 1.72            // Punkt i ↔ i+2 mindestens bendMin × Segment
        static let bendStiffness = 0.35
        static let maxBend = 0.9             // max. Knick Seilende ↔ Karte (rad)
        static let lengthSpring = 190.0, lengthDamping = 9.5   // Seillänge federt zur Ruhelänge
        static let minLength = ropeLength - 0.5 * unit, maxLength = 2.0318 * unit
        static let stretch = 0.16            // Anteil, um den Ziehen das Seil verlängert
        static let grabCard = 0.18, grabRope = 0.3   // Annäherung des gegriffenen Punkts pro Schritt
        static let dragUp = 0.3 * unit       // Karte max. so weit über die Ruhelage (pt)
        static let dragRadius = 0.8 * unit   // Karte max. so weit von der Ruhelage (pt)
        static let anchorMin = 1.85 * unit, anchorMax = 2.95 * unit   // Abstand Anker ↔ gezogene Karte
        static let releaseMax = 0.018 * unit // Wurfgeschwindigkeit, max. pt pro Schritt
        static let yawSpring = 46.0, yawDamping = 7.6
        static let flipKick = 1.2            // rad/s
        static let flipNudge = 0.0012 * unit, dropNudge = 0.0022 * unit   // pt
        static let hoverTilt = 0.32          // rad bei Zeiger am Rand
        static let hoverSpan = 1.5           // Zeigerabstand wird durch Breite × hoverSpan geteilt
        static let dragThreshold = 6.0       // pt bis Ziehen statt Klick
        static let clickTime = 0.45          // s
        static let bandHit = 9.0             // Trefferradius Band (pt)
        static let dropHeight = 3.0 * unit, dropTime = 1.3   // Einflug beim Erscheinen
        static let quietFrames = 24          // ruhige Frames bis Pause
        static let spinTrigger = 0.6 * unit  // 360°: Karte so weit rechts der Ruhelage (pt)
        static let spinRearm = 0.3 * unit    // erst wieder unter diesem Wert scharf
        static let spinLock = 1.5            // Sperre nach einer Drehung (s)
    }
    private static let clipH = 12.0, cardW = 160.0, cardH = 230.0, bandW = 10.0
    private static let frameW = 300.0, frameH = 330.0
    /// Ruhelage der Kartenmitte im Rahmen; der Anker liegt darüber außerhalb des Bilds.
    private static let rest = SIMD2(frameW / 2, 167.0)
    private static let anchor = SIMD2(rest.x, rest.y - Tune.ropeLength - Tune.attach)

    @AppStorage(NameBadge.nameKey) private var name = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = Rope()
    @State private var paused = false
    @State private var back = false           // nur „Bewegung reduzieren“
    @State private var offset = CGSize.zero   // nur „Bewegung reduzieren“
    @State private var press: Press?

    private struct Press { var part: Int?; var start: Date; var dragging = false }

    // MARK: Physik
    @MainActor final class Rope {
        typealias V = SIMD2<Double>
        static let card = Tune.segments + 1
        var p: [V], q: [V], w: [Double]
        var rest: [Double]                    // Sollabstände Punkt i ↔ i+1
        var length = Tune.ropeLength, lengthVel = 0.0
        var anchor = NameBadge.anchor
        var yaw = 0.0, yawVel = 0.0, face = 0.0, tilt = 0.0
        var grab: Int?, target = V.zero, grabOffset = V.zero
        var last: Date?, acc = 0.0, quiet = 0, before: [V] = [], yawBefore = 0.0
        var dropStart: Date?, dropDone = 0.0
        var spinArmed = true, spinUntil = Date.distantPast
        var seg: Double { length / Double(Tune.segments) }

        init() {
            let n = Tune.segments
            w = (0...n + 1).map { $0 == 0 ? 0 : ($0 == n + 1 ? Tune.cardInvMass : Tune.ropeInvMass) }
            rest = Array(repeating: Tune.ropeLength / Double(n), count: n) + [Tune.attach]
            p = []; q = []
            place(dy: 0)
        }

        /// Gerade herabhängend, um dy nach oben versetzt.
        func place(dy: Double) {
            let n = Tune.segments, s = Tune.ropeLength / Double(n)
            anchor = NameBadge.anchor - V(0, dy)
            p = (0...n).map { anchor + V(0, Double($0) * s) } + [anchor + V(0, Tune.ropeLength + Tune.attach)]
            q = p; length = Tune.ropeLength; lengthVel = 0; setLength(length)
        }

        func drop(_ now: Date) { place(dy: Tune.dropHeight); dropStart = now; dropDone = Tune.dropHeight }

        func setLength(_ l: Double) {
            length = l
            for i in 0..<Tune.segments { rest[i] = seg }
        }

        func clampLength(_ l: Double) -> Double { min(Tune.maxLength, max(Tune.minLength, l)) }

        func shift(_ i: Int, _ d: V) { p[i] += d; q[i] += d }

        func advance(_ now: Date) {
            let frame = last.map { min(Tune.maxFrame, max(0, now.timeIntervalSince($0))) } ?? Tune.dt
            last = now
            if let start = dropStart {   // Einflug: alles gemeinsam absenken (Geschwindigkeit bleibt)
                let a = min(1, now.timeIntervalSince(start) / Tune.dropTime), o = a - 1
                let s = Tune.dropHeight * (1 - (1 + 2.2 * o * o * o + 1.2 * o * o))
                let d = V(0, dropDone - s)
                for i in p.indices { shift(i, d) }
                anchor += d; dropDone = s
                if a >= 1 { dropStart = nil; p[Self.card].x += Tune.dropNudge }
            }
            acc += frame
            while acc >= Tune.dt { step(now); acc -= Tune.dt }
            quiet = isQuiet() ? quiet + 1 : 0
        }

        private func step(_ now: Date) {
            let dt = Tune.dt, c = Self.card
            p[0] = anchor; q[0] = anchor
            for i in 1...c {
                let k = i == c ? Tune.damping * Tune.cardDamping : Tune.damping
                let v = (p[i] - q[i]) * k
                q[i] = p[i]
                p[i] += v + V(0, Tune.gravity * dt * dt)
            }
            if let g = grab {
                let goal = target - grabOffset
                p[g] += (goal - p[g]) * (g == c ? Tune.grabCard : Tune.grabRope)
                var l = length
                if g == c {
                    let want = clampLength(simd_distance(goal, anchor) - Tune.attach)
                    l = want < length ? want : length + (want - length) * Tune.stretch
                }
                lengthVel = (l - length) / dt
                setLength(l)
            } else {
                lengthVel += (Tune.lengthSpring * (Tune.ropeLength - length) - Tune.lengthDamping * lengthVel) * dt
                setLength(clampLength(length + lengthVel * dt))
            }
            for _ in 0..<Tune.iterations {
                for i in 0..<c {   // Abstandsbedingungen
                    let d = p[i + 1] - p[i], dist = max(simd_length(d), 1e-6), m = w[i] + w[i + 1]
                    guard m > 0 else { continue }
                    let k = (dist - rest[i]) / (dist * m)
                    p[i] += d * (k * w[i]); p[i + 1] -= d * (k * w[i + 1])
                }
                let minD = seg * Tune.bendMin
                for i in 0..<(Tune.segments - 1) {   // Biegebedingung: nur Abstand nach unten begrenzen
                    let d = p[i + 2] - p[i], dist = max(simd_length(d), 1e-6), m = w[i] + w[i + 2]
                    guard dist < minD, m > 0 else { continue }
                    let k = (dist - minD) / (dist * m) * Tune.bendStiffness
                    p[i] += d * (k * w[i]); p[i + 2] -= d * (k * w[i + 2])
                }
            }
            followLeader()
            spinCheck(now)
            yawVel += (Tune.yawSpring * (face + tilt - yaw) - Tune.yawDamping * yawVel) * dt
            yaw += yawVel * dt
            if abs(face) >= 2 * .pi, abs(face + tilt - yaw) < 0.01, abs(yawVel) < 0.05 {   // volle Drehung fertig
                let turns = (face / (2 * .pi)).rounded() * 2 * .pi
                face -= turns; yaw -= turns
            }
        }

        /// Jeder Seilpunkt exakt eine Segmentlänge hinter den Vorgänger, Karte mit begrenztem Knick ans Ende.
        private func followLeader() {
            var dir = V(0, 1)
            for i in 1...Tune.segments {
                let d = p[i] - p[i - 1], l = simd_length(d)
                dir = l < 1e-9 ? V(0, 1) : d / l
                shift(i, p[i - 1] + dir * seg - p[i])
            }
            let end = p[Tune.segments], d = p[Self.card] - end, l = simd_length(d)
            var cd = l < 1e-9 ? dir : d / l
            let dot = simd_dot(cd, dir)
            if dot < cos(Tune.maxBend) {
                var side = cd - dir * dot
                side = simd_length_squared(side) < 1e-12 ? V(1, 0) : simd_normalize(side)
                cd = side * sin(Tune.maxBend) + dir * cos(Tune.maxBend)
            }
            shift(Self.card, end + cd * Tune.attach - p[Self.card])
        }

        /// 360°: Karte weit rechts der Ruhelage → einmal herumdrehen, danach Vorderseite.
        private func spinCheck(_ now: Date) {
            let dx = p[Self.card].x - NameBadge.rest.x
            if dx < Tune.spinRearm { spinArmed = true }
            guard dx > Tune.spinTrigger, spinArmed, now >= spinUntil else { return }
            spinArmed = false; spinUntil = now + Tune.spinLock
            face = 2 * .pi * ((face + 2 * .pi) / (2 * .pi)).rounded(.up)   // nächste Vorderseite ≥ 360° weiter
            yawVel += Tune.flipKick
        }

        func flip() {
            let toBack = cos(face) > 0
            face = toBack ? .pi : 0
            yawVel += toBack ? Tune.flipKick : -Tune.flipKick
            p[Self.card].x += Tune.flipNudge
        }

        /// Loslassen: Wurf übernehmen, aber Geschwindigkeit begrenzen.
        func release() {
            for i in 1...Self.card {
                let v = p[i] - q[i], l = simd_length(v)
                if l > Tune.releaseMax { q[i] = p[i] - v * (Tune.releaseMax / l) }
            }
            grab = nil
        }

        private func isQuiet() -> Bool {
            defer { before = p; yawBefore = yaw }
            guard grab == nil, dropStart == nil, before.count == p.count else { return false }
            let moved = zip(p, before).map { simd_distance_squared($0, $1) }.max() ?? 0
            let tol = 4e-8 * Tune.unit * Tune.unit
            return moved <= tol && abs(lengthVel) <= 1e-4 * Tune.unit
                && abs(yaw - yawBefore) <= 1e-4 && abs(face + tilt - yaw) <= 0.001
        }

        /// Richtung Seilende → Karte als Drehwinkel (0 = senkrecht nach unten, positiv im Uhrzeigersinn).
        var cardAngle: Double {
            let d = p[Self.card] - p[Tune.segments]
            return atan2(-d.x, d.y)
        }
    }

    // MARK: Body
    var body: some View {
        TimelineView(.animation(paused: reduceMotion ? press == nil && offset == .zero : paused)) { ctx in
            frame(ctx.date)
        }
        .frame(width: Self.frameW, height: Self.frameH, alignment: .top)
        .contentShape(Rectangle())
        .gesture(pointer)
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !reduceMotion, press?.part == nil else { return }
            switch phase {
            case .active(let at):
                let r = (at.x - Self.frameW / 2) / (Self.frameW * Tune.hoverSpan)
                model.tilt = min(1, max(-1, r)) * Tune.hoverTilt
            case .ended:
                model.tilt = 0
            }
            wake()
        }
        .onAppear {
            guard !reduceMotion else { return }
            wake(); model.drop(Date())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ausweiskarte: \(shown)")
    }

    private func frame(_ now: Date) -> some View {
        if reduceMotion {
            return hanging(points: [], center: Self.rest, angle: 0, yaw: back ? .pi : 0)
                .offset(offset)
        }
        model.advance(now)
        if model.quiet >= Tune.quietFrames && !paused { DispatchQueue.main.async { paused = true } }
        return hanging(points: Array(model.p[0...Tune.segments]), center: model.p[Rope.card],
                       angle: model.cardAngle, yaw: model.yaw)
            .offset(.zero)
    }

    private func hanging(points: [SIMD2<Double>], center: SIMD2<Double>, angle: Double, yaw: Double) -> some View {
        let down = SIMD2(-sin(angle), cos(angle))
        let top = center - down * (Self.cardH / 2)
        let band = points.isEmpty ? [Self.anchor, top] : points + [top]
        return ZStack(alignment: .topLeading) {
            Self.bandPath(band)
                .stroke(NordicCobalt.metalGradient, style: StrokeStyle(lineWidth: Self.bandW, lineJoin: .round))
                .overlay(Self.bandPath(band).stroke(Color.black.opacity(0.18), style: StrokeStyle(lineWidth: Self.bandW, lineJoin: .round)))
            Flip(angle: yaw * 180 / .pi, front: front(shine: angle), back: backSide)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                .frame(width: Self.cardW, height: Self.cardH)
                .overlay(alignment: .top) { clip.offset(y: -(Self.clipH / 2)) }
                .rotationEffect(.radians(angle))
                .position(x: center.x, y: center.y)
        }
        .frame(width: Self.frameW, height: Self.frameH, alignment: .topLeading)
    }

    /// Glatte Kurve durch die Seilpunkte (Mittelpunkte als Stützstellen).
    private static func bandPath(_ pts: [SIMD2<Double>]) -> Path {
        Path { path in
            guard let first = pts.first else { return }
            let cg = { (v: SIMD2<Double>) in CGPoint(x: v.x, y: v.y) }
            path.move(to: cg(first))
            for i in 1..<max(1, pts.count - 1) {
                path.addQuadCurve(to: cg((pts[i] + pts[i + 1]) / 2), control: cg(pts[i]))
            }
            if let last = pts.last { path.addLine(to: cg(last)) }
        }
    }

    // MARK: Zeiger
    private var pointer: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if press == nil { press = Press(part: hit(v.startLocation), start: Date()) }
                guard var pr = press, let part = pr.part else { return }
                if reduceMotion {
                    if part == Rope.card, hypot(v.translation.width, v.translation.height) >= Tune.dragThreshold {
                        offset = v.translation
                    }
                    return
                }
                let at = SIMD2(Double(v.location.x), Double(v.location.y))
                if !pr.dragging {
                    guard hypot(v.translation.width, v.translation.height) >= Tune.dragThreshold else { return }
                    pr.dragging = true; press = pr
                    model.grab = part; model.grabOffset = at - model.p[part]; model.tilt = 0
                }
                wake()
                guard part == Rope.card else { model.target = at; return }
                var s = at - model.grabOffset - Self.rest   // Kartenmitte relativ zur Ruhelage
                s.y = max(s.y, -Tune.dragUp)
                if simd_length(s) > Tune.dragRadius { s = simd_normalize(s) * Tune.dragRadius }
                var c = Self.rest + s
                let u = c - model.anchor, d = max(simd_length(u), 1e-6)
                c = model.anchor + u * (min(Tune.anchorMax, max(Tune.anchorMin, d)) / d)
                model.target = c + model.grabOffset
            }
            .onEnded { _ in
                defer { press = nil }
                guard let pr = press, let part = pr.part else { return }
                if reduceMotion {
                    if offset != .zero { offset = .zero } else if part == Rope.card { back.toggle() }
                    return
                }
                if pr.dragging { model.release() }
                else if part == Rope.card, Date().timeIntervalSince(pr.start) < Tune.clickTime { model.flip() }
                wake()
            }
    }

    /// Karte (Index `Rope.card`), nächster Seilpunkt des Bands oder nichts.
    private func hit(_ at: CGPoint) -> Int? {
        let p = SIMD2(Double(at.x), Double(at.y))
        let center = reduceMotion ? Self.rest : model.p[Rope.card]
        let a = reduceMotion ? 0 : model.cardAngle
        let d = p - center
        let u = d.x * cos(a) + d.y * sin(a), v = -d.x * sin(a) + d.y * cos(a)
        if abs(u) <= Self.cardW / 2, abs(v) <= Self.cardH / 2 { return Rope.card }
        guard !reduceMotion else { return nil }
        let near = (1...Tune.segments).min { simd_distance(model.p[$0], p) < simd_distance(model.p[$1], p) }!
        return simd_distance(model.p[near], p) <= Tune.bandHit ? near : nil
    }

    private func wake() { model.quiet = 0; if paused { model.last = nil; paused = false } }

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

    private var backSide: some View {
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
