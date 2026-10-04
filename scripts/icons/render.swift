// Renders an icon SVG to PNGs. Usage:
//   render.swift app   <in.svg> <out.iconset>   macOS app iconset (824 pt tile in a 1024 pt canvas)
//   render.swift glyph <in.svg> <out.png> <px>  square PNG at the given pixel size
import AppKit

func png(_ svg: String, _ px: Int, inset: CGFloat) -> Data {
    guard let image = NSImage(contentsOfFile: svg) else { fatalError("cannot load \(svg)") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = CGFloat(px) * (1 - 2 * inset)
    image.draw(in: NSRect(x: CGFloat(px) * inset, y: CGFloat(px) * inset, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let a = CommandLine.arguments
if a.count == 4 && a[1] == "app" {
    try FileManager.default.createDirectory(atPath: a[3], withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
            try png(a[2], base * scale, inset: 0.0977).write(to: URL(fileURLWithPath: a[3] + "/" + name))
        }
    }
} else if a.count == 5 && a[1] == "glyph", let px = Int(a[4]) {
    try png(a[2], px, inset: 0).write(to: URL(fileURLWithPath: a[3]))
} else {
    FileHandle.standardError.write(Data("usage: see header\n".utf8)); exit(2)
}
