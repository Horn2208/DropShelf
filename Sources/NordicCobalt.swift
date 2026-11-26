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
