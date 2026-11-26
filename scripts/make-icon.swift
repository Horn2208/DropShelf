#!/usr/bin/env swift
// Erzeugt Resources/Assets.xcassets/AppIcon.appiconset im Stil "Nordic Cobalt" (3D). Aufruf: swift scripts/make-icon.swift
import AppKit

let dir = "Resources/Assets.xcassets/AppIcon.appiconset"
let cs = CGColorSpaceCreateDeviceRGB()
func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}
func grad(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }
func vLine(_ c: CGContext, _ g: CGGradient, _ y0: CGFloat, _ y1: CGFloat) {
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Referenzbild (1024 px, Körper 222..803) -> Icon-Raster (Körper 100..924): Faktor 1.418
func R(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 512 + (x - 512.5) * 1.418, y: 512 + (y - 512) * 1.418) }

func arrowPath() -> CGPath {
    let p = CGMutablePath()
    let pts = [(476, 345), (549, 345), (549, 467), (610, 467), (512, 575), (413, 467), (476, 467)]
    p.addLines(between: pts.map { R(CGFloat($0.0), CGFloat($0.1)) }); p.closeSubpath()
    return p
}
func cupPath() -> CGPath {
    let p = CGMutablePath()
    func a(_ x: CGFloat, _ y: CGFloat) -> CGPoint { R(x, y) }
    let ro = 55 * 1.418, ri = 15 * 1.418
    p.move(to: a(330, 550))
    p.addArc(tangent1End: a(330, 680), tangent2End: a(693, 680), radius: ro)
    p.addArc(tangent1End: a(693, 680), tangent2End: a(693, 550), radius: ro)
    p.addLine(to: a(693, 550)); p.addLine(to: a(645, 550))
    p.addArc(tangent1End: a(645, 635), tangent2End: a(378, 635), radius: ri)
    p.addArc(tangent1End: a(378, 635), tangent2End: a(378, 550), radius: ri)
    p.addLine(to: a(378, 550)); p.closeSubpath()
    return p
}

/// Füllt einen Pfad mit vertikalem Verlauf, weichem Schatten, Glanzkante oben und dunkler Kante unten.
func glyph(_ c: CGContext, _ path: CGPath, _ g: CGGradient, shadow: CGFloat) {
    let b = path.boundingBox
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: shadow), blur: shadow * 2.2, color: col(0x000000, 0.55))
    c.addPath(path); c.setFillColor(col(0x000000)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(path); c.clip()
    vLine(c, g, b.minY, b.maxY)
    // Glanzkante oben
    c.addPath(path); c.setLineWidth(5); c.setStrokeColor(col(0xFFFFFF, 0.0)); 
    let hl = grad([col(0xFFFFFF, 0.65), col(0xFFFFFF, 0)], [0, 1])
    c.saveGState(); c.addPath(path); c.setLineWidth(7); c.replacePathWithStrokedPath(); c.clip()
    vLine(c, hl, b.minY, b.minY + b.height * 0.5); c.restoreGState()
    // dunkle Unterkante
    c.saveGState(); c.addPath(path); c.setLineWidth(6); c.replacePathWithStrokedPath(); c.clip()
    vLine(c, grad([col(0x000000, 0), col(0x000000, 0.28)]), b.minY + b.height * 0.5, b.maxY); c.restoreGState()
    c.restoreGState()
}

func render(_ px: Int, master: CGImage? = nil) -> CGImage {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    if let m = master { c.draw(m, in: CGRect(x: 0, y: 0, width: px, height: px)); return c.makeImage()! }
    // Arbeitsraum 1024, y nach unten
    c.translateBy(x: 0, y: 1024); c.scaleBy(x: 1, y: -1)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let rad = body.width * 0.225
    let bp = CGPath(roundedRect: body, cornerWidth: rad, cornerHeight: rad, transform: nil)
    let side = CGPath(roundedRect: body.offsetBy(dx: 0, dy: 10), cornerWidth: rad, cornerHeight: rad, transform: nil)
    // Schlagschatten + Körperdicke
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 28), blur: 44, color: col(0x000000, 0.45))
    c.addPath(side); c.setFillColor(col(0x0C0E11)); c.fillPath()
    c.restoreGState()
    // Körper
    c.saveGState(); c.addPath(bp); c.clip()
    vLine(c, grad([col(0x23272E), col(0x181B20), col(0x14171B)], [0, 0.45, 1]), body.minY, body.maxY)
    // sanftes Radiallicht
    c.drawRadialGradient(grad([col(0xFFFFFF, 0.06), col(0xFFFFFF, 0)]), startCenter: CGPoint(x: 512, y: 380), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 380), endRadius: 460, options: [])
    // gebürstete Struktur: feine Linien + Rauschen, sehr leise
    var seed: UInt64 = 42
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) & 0xFFFF) / 65535 }
    c.setLineWidth(1)
    for _ in 0..<1400 {
        let y = body.minY + rnd() * body.height, x = body.minX + rnd() * body.width, l = 80 + rnd() * 380
        c.setStrokeColor(col(rnd() > 0.5 ? 0xFFFFFF : 0x000000, 0.012 + rnd() * 0.03))
        c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + l, y: y + (rnd() - 0.5) * 2)); c.strokePath()
    }
    for _ in 0..<9000 {
        c.setFillColor(col(rnd() > 0.5 ? 0xFFFFFF : 0x000000, 0.02 + rnd() * 0.03))
        c.fill(CGRect(x: body.minX + rnd() * body.width, y: body.minY + rnd() * body.height, width: 1.5, height: 1.5))
    }
    c.restoreGState()
    // Innenkante + Kantenlicht oben
    c.saveGState(); c.addPath(bp); c.setLineWidth(4); c.replacePathWithStrokedPath(); c.clip()
    vLine(c, grad([col(0xFFFFFF, 0.38), col(0xFFFFFF, 0.04), col(0x000000, 0.35)], [0, 0.4, 1]), body.minY, body.maxY)
    c.restoreGState()
    // Schale (schwebt unter dem Pfeil) und Pfeil
    glyph(c, cupPath(), grad([col(0xCBD5E1), col(0x94A3B8)]), shadow: 14)
    glyph(c, arrowPath(), grad([col(0x38BDF8), col(0x2563EB)]), shadow: 16)
    return c.makeImage()!
}

func png(_ i: CGImage) -> Data { NSBitmapImageRep(cgImage: i).representation(using: .png, properties: [:])! }

let master = render(1024)
var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let img = base * scale == 1024 ? master : render(base * scale, master: master)
        try! png(img).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(base)x\#(base)"}"#)
    }
}
let json = #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
try! json.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
try! #"{"info":{"author":"xcode","version":1}}"#.write(toFile: "Resources/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
