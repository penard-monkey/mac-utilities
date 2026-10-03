import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let s = CGFloat(size)
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.20, yRadius: s * 0.20)
    NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.46, blue: 0.85, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.52, alpha: 1))!.draw(in: shape, angle: -80)
    NSColor.white.setStroke()
    let line = NSBezierPath()
    line.lineWidth = s * 0.055
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: s * 0.35, y: s * 0.28))
    line.line(to: NSPoint(x: s * 0.35, y: s * 0.73))
    line.move(to: NSPoint(x: s * 0.35, y: s * 0.45))
    line.curve(to: NSPoint(x: s * 0.67, y: s * 0.69), controlPoint1: NSPoint(x: s * 0.68, y: s * 0.45), controlPoint2: NSPoint(x: s * 0.67, y: s * 0.52))
    line.stroke()
    for (x, y) in [(0.35, 0.28), (0.35, 0.73), (0.67, 0.70)] {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: s * (x - 0.075), y: s * (y - 0.075), width: s * 0.15, height: s * 0.15)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
}
