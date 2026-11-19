#!/usr/bin/env swift
// Erzeugt Resources/Assets.xcassets/AppIcon.appiconset (alle macOS-Größen). Aufruf: swift scripts/make-icon.swift
import AppKit

let dir = "Resources/Assets.xcassets/AppIcon.appiconset"

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)  // Icon-Raster: 824/1024
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.black.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.33, green: 0.25, blue: 0.80, alpha: 1))!.draw(in: path, angle: -60)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.36, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let k = min(body.width * 0.55 / tinted.size.width, body.height * 0.55 / tinted.size.height)
        let w = tinted.size.width * k, h = tinted.size.height * k
        tinted.draw(in: NSRect(x: s / 2 - w / 2, y: s / 2 - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(base * scale).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(base)x\#(base)"}"#)
    }
}
let json = #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
try! json.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
try! #"{"info":{"author":"xcode","version":1}}"#.write(toFile: "Resources/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
