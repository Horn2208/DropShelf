#!/usr/bin/env swift
// Erzeugt Resources/Assets.xcassets/MenuBarIcon.imageset (schwarzes Template, 18 und 36 px). Aufruf: swift scripts/make-menubar-icon.swift
import AppKit

let dir = "Resources/Assets.xcassets/MenuBarIcon.imageset"
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Glyph (Referenzkoordinaten x 330..693, y 345..680, y nach unten) auf 1 px Rand einpassen
    let k = CGFloat(px - 2 * px / 18) / 363, s = CGFloat(px)
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 511.5) * k + s / 2, y: s - ((y - 512.5) * k + s / 2)) }
    c.setFillColor(CGColor(gray: 0, alpha: 1))
    c.addLines(between: [(476, 345), (549, 345), (549, 467), (610, 467), (512, 575), (413, 467), (476, 467)].map { P(CGFloat($0.0), CGFloat($0.1)) })
    c.closePath(); c.fillPath()
    let ro = 55 * k * 0.8, ri = 8 * k
    let p = CGMutablePath()
    p.move(to: P(330, 550))
    p.addArc(tangent1End: P(330, 680), tangent2End: P(693, 680), radius: ro)
    p.addArc(tangent1End: P(693, 680), tangent2End: P(693, 550), radius: ro)
    p.addLine(to: P(693, 550)); p.addLine(to: P(645, 550))
    p.addArc(tangent1End: P(645, 635), tangent2End: P(378, 635), radius: ri)
    p.addArc(tangent1End: P(378, 635), tangent2End: P(378, 550), radius: ri)
    p.addLine(to: P(378, 550)); p.closeSubpath()
    c.addPath(p); c.fillPath()
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

try! render(18).write(to: URL(fileURLWithPath: "\(dir)/MenuBarIcon.png"))
try! render(36).write(to: URL(fileURLWithPath: "\(dir)/MenuBarIcon@2x.png"))
try! #"{"images":[{"filename":"MenuBarIcon.png","idiom":"universal","scale":"1x"},{"filename":"MenuBarIcon@2x.png","idiom":"universal","scale":"2x"}],"info":{"author":"xcode","version":1},"properties":{"template-rendering-intent":"template"}}"#
    .write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
