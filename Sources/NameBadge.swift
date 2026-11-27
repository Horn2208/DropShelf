import SwiftUI

/// Ausweiskarte an einem Band. Pendel: gedämpfte Schwingung, analytisch aus der Zeit seit dem letzten Anstoß
/// berechnet (TimelineView), Klick dreht die Karte um die vertikale Achse.
struct NameBadge: View {
    static let nameKey = "userDisplayName"
    @AppStorage(NameBadge.nameKey) private var name = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kick = Date()
    @State private var kickAmp = 9.0   // Grad
    @State private var spin = 0.0

    private func swing(at t: Date) -> Double {
        guard !reduceMotion else { return 0 }
        let s = t.timeIntervalSince(kick)
        return kickAmp * exp(-1.1 * s) * cos(2.6 * s)  // ponytail: feste Frequenz/Dämpfung, kein echtes Pendel
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            VStack(spacing: 0) {
                Rectangle().fill(NordicCobalt.metalGradient).frame(width: 14, height: 46)
                Capsule().fill(NordicCobalt.metalGradient).frame(width: 26, height: 8)
                card.rotation3DEffect(.degrees(spin), axis: (0, 1, 0), perspective: 0.5)
                    .onTapGesture {
                        guard !reduceMotion else { return }
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { spin += 360 }
                        kick = Date(); kickAmp = 6
                    }
            }
            .rotationEffect(.degrees(swing(at: ctx.date)), anchor: .top)
        }
        .frame(width: 220, height: 300, alignment: .top).clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ausweiskarte: \(shown)")
    }

    private var shown: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Dein Name" : n
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACCESS PASS").font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(NordicCobalt.highlight)
            Spacer()
            Text(shown).font(.system(size: 26, weight: .bold)).lineLimit(2).minimumScaleFactor(0.5)
                .foregroundStyle(.white)
            Spacer()
            HStack {
                Text("DROPSHELF"); Spacer(); Text("v\(appVersion)")
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
        }
        .padding(18).frame(width: 170, height: 220)
        .background(LinearGradient(colors: [NordicCobalt.accent, NordicCobalt.deep],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
    }
}
