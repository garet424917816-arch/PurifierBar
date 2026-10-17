// Draws the neutral app icon (without "Xiaomi"/"Mi") and builds Resources/AppIcon.icns.
//   swift Tools/make-icon.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Drawing in a 1024 x 1024 coordinate system.
func draw(in ctx: CGContext) {
    // Body on the macOS grid: 824 x 824 with a 100 inset, radius ~185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.16, green: 0.42, blue: 0.80, alpha: 1).cgColor,
        NSColor(srgbRed: 0.18, green: 0.78, blue: 0.80, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])

    // Purifier grille: a ring.
    let center = CGPoint(x: 512, y: 512)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(34)
    ctx.addArc(center: center, radius: 290, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Airflow: three waves inside the ring.
    ctx.setLineWidth(40)
    for (dy, inset) in [(110.0, 70.0), (0.0, 30.0), (-110.0, 70.0)] {
        let y = center.y + dy
        let left = center.x - 230 + inset
        let right = center.x + 230 - inset
        let third = (right - left) / 3
        ctx.move(to: CGPoint(x: left, y: y))
        ctx.addCurve(
            to: CGPoint(x: left + third * 1.5, y: y),
            control1: CGPoint(x: left + third * 0.5, y: y + 42),
            control2: CGPoint(x: left + third, y: y + 42)
        )
        ctx.addCurve(
            to: CGPoint(x: right, y: y),
            control1: CGPoint(x: left + third * 2, y: y - 42),
            control2: CGPoint(x: left + third * 2.5, y: y - 42)
        )
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func png(size: Int) throws -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil: \(iconutil.terminationStatus)") }
try png(size: 1024).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-preview.png"))
print("make-icon: Resources/AppIcon.icns")
