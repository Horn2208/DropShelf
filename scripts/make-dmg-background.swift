#!/usr/bin/env swift
// Erzeugt Resources/dmg/background.png, background@2x.png, background.tiff (HiDPI) und docs/dmg-preview.png.
// Die Icon-Positionen müssen zu scripts/make-dmg.sh passen (ICON_APP_X/Y, ICON_APPS_X/Y; Finder-Koordinaten, Ursprung oben links).
import AppKit

let W = 540.0, H = 380.0
let appX = 140.0, appsX = 400.0, iconY = 170.0   // Icon-Mittelpunkte
func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a) }

func render(scale: Double, withIcons: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // 144 dpi bei @2x
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let full = NSRect(x: 0, y: 0, width: W, height: H)
    NSGradient(starting: hex(0xF3F1EC), ending: hex(0xE4E2DB))!.draw(in: full, angle: -90)

    let y = H - iconY   // AppKit-Koordinate
    // Pfeil: dicker, abgerundeter Schaft + offene Spitze (Chevron), Kobalt-Verlauf
    let x0 = appX + 80, x1 = appsX - 80, th = 7.0, hh = 30.0, hl = 26.0
    let arrow = NSBezierPath()
    arrow.lineWidth = th * 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: x0 + th, y: y)); arrow.line(to: NSPoint(x: x1 - th, y: y))
    arrow.move(to: NSPoint(x: x1 - th - hl, y: y + hh)); arrow.line(to: NSPoint(x: x1 - th, y: y)); arrow.line(to: NSPoint(x: x1 - th - hl, y: y - hh))
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.addPath(arrow.cgPath.copy(strokingWithWidth: arrow.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    NSGradient(starting: hex(0x2563EB), ending: hex(0x38BDF8))!.draw(in: NSRect(x: x0, y: y - hh - th, width: x1 - x0, height: 2 * (hh + th)), angle: 0)
    ctx.restoreGState()

    let text = NSAttributedString(string: "Ziehe DropShelf in den Programme-Ordner",
        attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: hex(0x64748B)])
    text.draw(at: NSPoint(x: (W - text.size().width) / 2, y: 70))

    if withIcons {   // nur Vorschau: App-Icon + Programme-Ordner mit Beschriftung
        let icon = NSImage(contentsOfFile: "Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")!
        icon.draw(in: NSRect(x: appX - 48, y: y - 48, width: 96, height: 96))
        NSWorkspace.shared.icon(forFile: "/Applications").draw(in: NSRect(x: appsX - 48, y: y - 48, width: 96, height: 96))
        for (n, x) in [("DropShelf", appX), ("Programme", appsX)] {
            let s = NSAttributedString(string: n, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: hex(0x181B20)])
            s.draw(at: NSPoint(x: x - s.size().width / 2, y: y - 68))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func save(_ rep: NSBitmapImageRep, _ path: String) { try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)) }

try? FileManager.default.createDirectory(atPath: "Resources/dmg", withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: "docs", withIntermediateDirectories: true)
save(render(scale: 1, withIcons: false), "Resources/dmg/background.png")
save(render(scale: 2, withIcons: false), "Resources/dmg/background@2x.png")
save(render(scale: 2, withIcons: true), "docs/dmg-preview.png")
let t = Process()
t.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
t.arguments = ["-cathidpicheck", "Resources/dmg/background.png", "Resources/dmg/background@2x.png", "-out", "Resources/dmg/background.tiff"]
try! t.run(); t.waitUntilExit()
