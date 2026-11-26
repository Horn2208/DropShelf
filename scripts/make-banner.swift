#!/usr/bin/env swift
// Erzeugt docs/banner-light.png und docs/banner-dark.png (1280x640). Braucht das App-Icon (erst make-icon.swift ausführen).
import AppKit

let icon = NSImage(contentsOfFile: "Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")!
func hex(_ h: UInt32) -> NSColor { NSColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }

func banner(_ file: String, bg: UInt32, title: UInt32, sub: UInt32) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    hex(bg).setFill(); NSRect(x: 0, y: 0, width: 1280, height: 640).fill()
    icon.draw(in: NSRect(x: 110, y: 120, width: 400, height: 400))
    NSAttributedString(string: "DropShelf", attributes: [.font: NSFont.systemFont(ofSize: 104, weight: .bold), .foregroundColor: hex(title)])
        .draw(at: NSPoint(x: 540, y: 300))
    NSAttributedString(string: "Menüleisten-Ablage für Dateien", attributes: [.font: NSFont.systemFont(ofSize: 40, weight: .regular), .foregroundColor: hex(sub)])
        .draw(at: NSPoint(x: 548, y: 235))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
}
try? FileManager.default.createDirectory(atPath: "docs", withIntermediateDirectories: true)
banner("docs/banner-light.png", bg: 0xECEAE4, title: 0x181B20, sub: 0x64748B)
banner("docs/banner-dark.png", bg: 0x11141A, title: 0xF8FAFC, sub: 0x94A3B8)
