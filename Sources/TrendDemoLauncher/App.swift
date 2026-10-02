import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Dock icon

/// Render the Forge mark (graphite squircle + red anvil and strike spark) at runtime
/// and use it as the Dock icon. Pixel-identical to `AppIcon.swift`, which bakes the
/// same art into the .app bundle's .icns — but this also covers the unbundled dev
/// binary, which has no Info.plist and would otherwise show the generic "exec" tile.
private func brandAppIcon(px: Int = 1024) -> NSImage? {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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
    if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: tile.minX, y: tile.maxY),
                               end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    }
    ctx.restoreGState()

    // The anvil + strike spark. The glyph box is enlarged so the mark reads boldly while a
    // clear border remains (~12% at the sides, ~19% top/bottom), and it rides low in the tile
    // so the spark-topped ink ends up vertically centered. The unit coordinates below are
    // authored top-down (matching AnvilShape in BrandMarks.swift); CG's y-axis points up, so
    // flip on the way in.
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
    if let sg = CGGradient(colorsSpace: cs, colors: sparkColors, locations: [0, 1]) {
        ctx.drawLinearGradient(sg,
                               start: CGPoint(x: box.minX, y: box.maxY),
                               end: CGPoint(x: box.maxX, y: box.minY), options: [])
    }
    ctx.restoreGState()

    guard let cg = ctx.makeImage() else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: s, height: s))
}

// MARK: - App Delegate (window resizability)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // This runs as an unbundled SwiftPM executable (no Info.plist), so AppKit
        // may not promote it to a regular, activatable app on its own. Without this,
        // the window can fail to become key — mouse clicks work but keyboard input
        // (e.g. typing into the embedded terminal) never routes anywhere.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Show the brand spark in the Dock (overrides the generic dev-binary icon).
        if let icon = brandAppIcon() { NSApp.applicationIconImage = icon }

        // Apply the saved Light / Dark / System appearance preference (nil = follow system).
        AppearanceMode.current.apply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - App

@main
struct TrendDemoLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var runner = DemoRunner()
    /// Interface font scale, persisted directly. Every `.scaledFont` reads the same
    /// @AppStorage key, so menu changes apply everywhere without a shared object.
    @AppStorage(FontScale.key) private var uiScale: Double = 1.0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runner)
                // Only set min — do NOT set max (a max locks the window size).
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Settings keeps the standard macOS "Settings… ⌘," from the Settings scene.
            // Add to the EXISTING "View" menu (after the sidebar item), not a second one.
            CommandGroup(after: .sidebar) {
                Button("Zoom In")  { uiScale = FontScale.zoomedIn(uiScale) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { uiScale = FontScale.zoomedOut(uiScale) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { uiScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()
            }
        }

        Settings {
            SettingsView()
                .environmentObject(runner)
        }
    }
}
