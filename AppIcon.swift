// Generates the app-icon PNG set (a near-black squircle with the red Forge mark —
// an anvil with a strike spark). Keep the glyph geometry in sync with brandAppIcon()
// in Sources/TrendDemoLauncher/App.swift and AnvilShape in BrandMarks.swift.
// Uses CoreGraphics only — no AppKit/WindowServer — so it runs headless reliably.
// Usage: swift AppIcon.swift <output.iconset dir>

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(px: Int) -> CGImage {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Rounded-square tile filled near-black (subtle top-down gradient for depth).
    let inset = s * 0.085
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let colors = [CGColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
                  CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // The anvil + strike spark. The glyph box is enlarged so the mark reads boldly while a
    // clear border remains (~12% at the sides, ~19% top/bottom), and it rides low in the tile
    // so the spark-topped ink ends up vertically centered. Unit coordinates are authored
    // top-down (matching AnvilShape in BrandMarks.swift); CG's y-axis points up, so flip in.
    let box = CGRect(x: tile.minX + tile.width * 0.087,
                     y: tile.minY + tile.height * 0.0378,
                     width: tile.width * 0.826,
                     height: tile.height * 0.751)
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x * box.width, y: box.minY + (1 - y) * box.height)
    }
    let glyph = CGMutablePath()
    glyph.move(to: P(0.04, 0.30))                                        // horn tip
    glyph.addQuadCurve(to: P(0.34, 0.22), control: P(0.15, 0.22))        // horn top → face
    glyph.addLine(to: P(0.96, 0.22))                                     // face top edge
    glyph.addLine(to: P(0.96, 0.38))                                     // right edge
    glyph.addLine(to: P(0.72, 0.44))                                     // undercut
    glyph.addLine(to: P(0.68, 0.60))                                     // waist right
    glyph.addLine(to: P(0.86, 0.68))                                     // flare to base
    glyph.addLine(to: P(0.86, 0.80))
    glyph.addLine(to: P(0.32, 0.80))                                     // base
    glyph.addLine(to: P(0.32, 0.68))
    glyph.addLine(to: P(0.50, 0.60))                                     // waist left
    glyph.addLine(to: P(0.46, 0.44))
    glyph.addLine(to: P(0.34, 0.40))                                     // undercut
    glyph.addQuadCurve(to: P(0.04, 0.30), control: P(0.15, 0.38))        // horn underside
    glyph.closeSubpath()

    // Strike spark above the face.
    let sc = P(0.70, 0.09)
    let sr = box.width * 0.11
    let ii = sr * 0.36
    let sparkPts = [
        CGPoint(x: sc.x, y: sc.y + sr), CGPoint(x: sc.x + ii, y: sc.y + ii),
        CGPoint(x: sc.x + sr, y: sc.y), CGPoint(x: sc.x + ii, y: sc.y - ii),
        CGPoint(x: sc.x, y: sc.y - sr), CGPoint(x: sc.x - ii, y: sc.y - ii),
        CGPoint(x: sc.x - sr, y: sc.y), CGPoint(x: sc.x - ii, y: sc.y + ii),
    ]
    glyph.move(to: sparkPts[0])
    for q in sparkPts.dropFirst() { glyph.addLine(to: q) }
    glyph.closeSubpath()

    ctx.saveGState()
    ctx.addPath(glyph); ctx.clip()
    let sparkColors = [CGColor(red: 0.97, green: 0.27, blue: 0.30, alpha: 1),
                       CGColor(red: 0.80, green: 0.07, blue: 0.13, alpha: 1)] as CFArray
    let sg = CGGradient(colorsSpace: cs, colors: sparkColors, locations: [0, 1])!
    ctx.drawLinearGradient(sg,
                           start: CGPoint(x: box.minX, y: box.maxY),
                           end: CGPoint(x: box.maxX, y: box.minY), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes { writePNG(drawIcon(px: px), to: "\(outDir)/\(name).png") }
print("Wrote \(sizes.count) icon PNGs to \(outDir)")
