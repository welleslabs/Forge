import SwiftUI
import AppKit

// MARK: - Design Tokens
//
// A single source of truth for the app's quiet, neutral look: true-gray surfaces,
// hairline borders, and one restrained red accent. Keeping colors, radii, and
// reusable surfaces here lets every view stay consistent and makes a future
// re-skin a one-file change.

enum Theme {

    // MARK: Adaptive color resolution
    //
    // Every token resolves per macOS appearance (Aqua = Light, Dark Aqua = Dark) by backing
    // a SwiftUI Color with a dynamic NSColor. Views simply read `Theme.x` and the whole UI
    // follows the system Light/Dark setting — no per-view work, and it updates live.
    private static func dyn(_ light: (Double, Double, Double),
                            _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let c = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// A neutral overlay tint whose polarity flips by appearance: a subtle dark tint on light
    /// backgrounds, a subtle light tint on dark. For hovers, selected rows, and inset panels.
    static func tint(_ amount: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: amount)
                : NSColor(white: 0, alpha: amount)
        })
    }

    /// A hairline whose polarity flips by appearance (dark line on light, light line on dark).
    private static func hairline(_ lightAlpha: Double, _ darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: darkAlpha)
                : NSColor(white: 0, alpha: lightAlpha)
        })
    }

    // Backgrounds — flat neutral grays (no color cast). Light mode is deliberately
    // softened: off-white cards on a mid-gray page, so nothing glares. Dark mode is
    // graphite cards on near-black.
    static let bg0       = dyn((0.925, 0.925, 0.930), (0.106, 0.106, 0.110))   // window base
    static let bg1       = dyn((0.905, 0.905, 0.910), (0.125, 0.125, 0.129))   // sidebar
    static let surface   = dyn((0.980, 0.980, 0.985), (0.157, 0.157, 0.163))   // cards
    static let surfaceHi = dyn((0.950, 0.950, 0.955), (0.198, 0.198, 0.206))   // elevated / hover

    // Hairlines — visible enough to define cards without turning into grid lines.
    static let stroke    = hairline(0.10, 0.10)
    static let strokeHi  = hairline(0.18, 0.16)

    // Text — high contrast in both themes so nothing needs squinting: near-black on
    // light, bright neutrals on dark. Tertiary is for true fine print only.
    static let textPri = dyn((0.080, 0.080, 0.090), (0.980, 0.980, 0.990))
    static let textSec = dyn((0.250, 0.250, 0.270), (0.860, 0.860, 0.880))
    static let textTer = dyn((0.400, 0.400, 0.420), (0.700, 0.700, 0.720))

    /// The single accent — a refined Trend red, used sparingly: primary action buttons,
    /// links, and the app mark. Everything else stays neutral.
    static let accent = dyn((0.720, 0.110, 0.180), (0.880, 0.380, 0.420))

    // Radii
    static let rCard: CGFloat = 12
    static let rTile: CGFloat = 10
    static let rPill: CGFloat = 8
}

// MARK: - App Background

/// Full-window backdrop — a single flat surface. Kept deliberately plain (no glows or dot
/// texture) so content reads cleanly and nothing competes with the text for attention.
struct AppBackground: View {
    var body: some View {
        Theme.bg0.ignoresSafeArea()
    }
}

// MARK: - Reusable Surfaces

/// A flat card surface with a hairline border and a subtle neutral elevation shadow.
struct SoftCard: ViewModifier {
    var radius: CGFloat = Theme.rCard
    var highlighted: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(highlighted ? Theme.strokeHi : Theme.stroke,
                            lineWidth: highlighted ? 1.2 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }
}

extension View {
    func softCard(radius: CGFloat = Theme.rCard,
                  highlighted: Bool = false) -> some View {
        modifier(SoftCard(radius: radius, highlighted: highlighted))
    }
}

// MARK: - Status Pill

/// A quiet tag: sentence-case text on a lightly tinted background. Status semantics come
/// from the color (usually one of LabStatus's muted red/amber/green).
struct StatusPill: View {
    let text: String
    var color: Color = Theme.textSec

    var body: some View {
        Text(text)
            .scaledFont(11.5, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(color.opacity(0.25), lineWidth: 0.75)
            )
    }
}

// MARK: - Brand Spinner
//
// A pure-SwiftUI rotating arc. Replaces ProgressView() (an AppKit NSProgressIndicator)
// which spams Auto Layout constraint warnings when forced into a frame smaller than
// its intrinsic size. This draws with shapes only — no AppKit, no constraints, no spam.
struct BrandSpinner: View {
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2
    var colors: [Color] = [Theme.accent, Theme.accent.opacity(0.25)]
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                AngularGradient(colors: colors + [colors.first ?? Theme.accent],
                                center: .center),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Interface font scaling (View ▸ Zoom / Font Size)

/// Interface font scale, persisted in `@AppStorage("uiScale")`. Every `.scaledFont` reads
/// the key directly, so a change re-renders all scaled text — without a shared
/// ObservableObject whose `objectWillChange` would redraw the whole view tree at once.
enum FontScale {
    static let key = "uiScale"
    static let minScale = 0.7
    static let maxScale = 1.8
    /// Round to the nearest 0.01 so repeated steps don't accumulate floating-point drift.
    private static func snap(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func zoomedIn(_ v: Double)  -> Double { Swift.min(maxScale, snap(v + 0.1)) }
    static func zoomedOut(_ v: Double) -> Double { Swift.max(minScale, snap(v - 0.1)) }
}

private struct ScaledFontModifier: ViewModifier {
    @AppStorage(FontScale.key) private var scale: Double = 1.0
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    func body(content: Content) -> some View {
        content.font(.system(size: size * CGFloat(scale), weight: weight, design: design))
    }
}

extension View {
    /// Drop-in for `.font(.system(size:weight:design:))` that scales with the View-menu
    /// zoom. Uses real font sizes (no transform), so layout and mouse hit-testing stay correct.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

// MARK: - Appearance preference (Settings ▸ Appearance)

/// The user's chosen app appearance. Applied by overriding `NSApp.appearance` app-wide
/// (nil = follow the macOS system setting). Persisted under AppSettings.Keys.appearance and
/// surfaced as a System / Light / Dark toggle in Settings.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static var key: String { AppSettings.Keys.appearance }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// The AppKit appearance to force app-wide, or nil to follow the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// The saved preference (defaults to .system).
    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Apply app-wide — overrides every window and SwiftUI dynamic color. nil follows the system.
    func apply() { NSApplication.shared.appearance = nsAppearance }
}
