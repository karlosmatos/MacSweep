#!/usr/bin/env swift
// Draws the MacSweep app icon (free-space ring around the menu bar sparkle) and writes Resources/AppIcon.icns.
// Run: swift scripts/generate_icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
let accent = NSColor(red: 0.247, green: 0.761, blue: 0.557, alpha: 1)

func draw(size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824 pt body, 100 pt margin, soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor(red: 0.075, green: 0.102, blue: 0.090, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Light from above, kept faint.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let light = CGGradient(colorsSpace: nil, colors: [NSColor.white.withAlphaComponent(0.07).cgColor,
                                                      NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(light, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 500), options: [])
    ctx.restoreGState()

    // Ring: track plus a three-quarter accent arc, starting at 12 o'clock and running clockwise.
    let center = CGPoint(x: 512, y: 512)
    ctx.setLineWidth(62)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: 268, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
    ctx.strokePath()
    ctx.addArc(center: center, radius: 268, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.5, clockwise: true)
    ctx.setStrokeColor(accent.cgColor)
    ctx.strokePath()

    // Four-point sparkle with concave sides.
    let r: CGFloat = 150, k: CGFloat = 22
    let star = CGMutablePath()
    let tips = [CGPoint(x: 0, y: r), CGPoint(x: r, y: 0), CGPoint(x: 0, y: -r), CGPoint(x: -r, y: 0)]
    star.move(to: tips[0])
    for i in 0..<4 {
        let a = tips[i], b = tips[(i + 1) % 4]
        let control = CGPoint(x: (a.x + b.x) / 2 * k / r * 2, y: (a.y + b.y) / 2 * k / r * 2)
        star.addQuadCurve(to: b, control: control)
    }
    ctx.translateBy(x: center.x, y: center.y)
    ctx.addPath(star)
    ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
    ctx.fillPath()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! draw(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
