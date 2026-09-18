// Renders an .iconset from a single PNG: `swift tools/make-icon.swift icon.png build/AppIcon.iconset`
// The artwork is center-cropped to a square and drawn at ~80% of the canvas, matching Apple's
// icon grid (824 px squircle on a 1024 px canvas) so it sits at the same size as other app icons.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon <src.png> <out.iconset>\n".utf8))
    exit(1)
}
let outDir = args[2]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let side = min(src.size.width, src.size.height)
let crop = NSRect(x: (src.size.width - side) / 2, y: (src.size.height - side) / 2, width: side, height: side)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let inset = CGFloat(px) * 0.0977
    let dst = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    src.draw(in: dst, from: crop, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    try render(px).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
