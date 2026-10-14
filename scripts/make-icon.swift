// Draws the app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
// The icon is drawn with Core Graphics only (no SF Symbols, which Apple does not allow in app icons):
// a gauge on a rounded square that follows the macOS icon grid (824 pt body on a 1024 pt canvas).
import AppKit

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in context: CGContext, size: CGFloat) {
    let scale = size / 1024
    context.scaleBy(x: scale, y: scale)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Shadow under the body, as on system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x1C2230))
    context.fillPath()
    context.restoreGState()

    // Body: dark slate gradient.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [color(0x2E3648), color(0x151A24)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let center = CGPoint(x: 512, y: 440)
    let radius: CGFloat = 270
    let start = CGFloat.pi * 1.1   // lower left
    let end = CGFloat.pi * -0.1    // lower right
    let lineWidth: CGFloat = 74

    // Track.
    context.setLineCap(.round)
    context.setLineWidth(lineWidth)
    context.setStrokeColor(color(0xFFFFFF, 0.12))
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    context.strokePath()

    // Filled part: green (Codex) through clay (Claude) to red, two thirds of the way.
    let filledEnd = start - (start - end) * 0.68
    context.saveGState()
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: filledEnd, clockwise: true)
    context.replacePathWithStrokedPath()
    context.clip()
    let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x2CC497), color(0xE8896B), color(0xFF6369)] as CFArray,
                          locations: [0, 0.6, 1])!
    context.drawLinearGradient(fill, start: CGPoint(x: center.x - radius - 40, y: center.y),
                               end: CGPoint(x: center.x + radius + 40, y: center.y), options: [])
    context.restoreGState()

    // Needle and hub.
    let needleAngle = filledEnd
    let tip = CGPoint(x: center.x + cos(needleAngle) * (radius - 70), y: center.y + sin(needleAngle) * (radius - 70))
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(30)
    context.move(to: center)
    context.addLine(to: tip)
    context.strokePath()
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: center.x - 46, y: center.y - 46, width: 92, height: 92))
    context.setFillColor(color(0x1C2230))
    context.fillEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))

    // Soft highlight at the top edge.
    let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    context.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    drawIcon(in: graphics.cgContext, size: CGFloat(size))
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try png(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
print("Wrote \(output.path)")
