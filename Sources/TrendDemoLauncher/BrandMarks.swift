import SwiftUI

// MARK: - Brand Mark Kinds
//
// Products map to crisp SF Symbols in quiet tiles; the app itself gets a custom
// Forge mark — an anvil with a strike spark — so the launcher has an identity of
// its own without the product icons competing for attention.

enum BrandMarkKind {
    case scanner       // AI Scanner
    case shield        // AI Guard
    case codeScan      // Code Security
    case code          // Container Security
    case cloud         // Cloud Risk Management
    case access        // AI Secure Access
    case insights      // AI Risk Insights
    case forge         // App mark

    var symbol: String {
        switch self {
        case .scanner:  return "sparkle.magnifyingglass"
        case .shield:   return "shield.fill"
        case .codeScan: return "chevron.left.forwardslash.chevron.right"
        case .code:     return "shippingbox.fill"
        case .cloud:    return "cloud.fill"
        case .access:   return "lock.shield.fill"
        case .insights: return "chart.bar.fill"
        case .forge:    return "sparkle"   // fallback only — .forge renders ForgeGlyph
        }
    }
}

// MARK: - Forge Mark

/// A minimal anvil silhouette. Unit coordinates run top-down; one clean shape so it
/// stays crisp from 16 pt (sidebar) to 1024 px (app icon).
struct AnvilShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var p = Path()
        p.move(to: pt(0.04, 0.30))                                        // horn tip
        p.addQuadCurve(to: pt(0.34, 0.22), control: pt(0.15, 0.22))       // horn top → face
        p.addLine(to: pt(0.96, 0.22))                                     // face top edge
        p.addLine(to: pt(0.96, 0.38))                                     // right edge
        p.addLine(to: pt(0.72, 0.44))                                     // undercut
        p.addLine(to: pt(0.68, 0.60))                                     // waist right
        p.addLine(to: pt(0.86, 0.68))                                     // flare to base
        p.addLine(to: pt(0.86, 0.80))
        p.addLine(to: pt(0.32, 0.80))                                     // base
        p.addLine(to: pt(0.32, 0.68))
        p.addLine(to: pt(0.50, 0.60))                                     // waist left
        p.addLine(to: pt(0.46, 0.44))
        p.addLine(to: pt(0.34, 0.40))                                     // undercut
        p.addQuadCurve(to: pt(0.04, 0.30), control: pt(0.15, 0.38))       // horn underside
        p.closeSubpath()
        return p
    }
}

/// The four-point spark that flies off the anvil face — the "strike".
struct StrikeSparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let inner = r * 0.36
        let pts: [CGPoint] = [
            CGPoint(x: c.x, y: c.y - r),
            CGPoint(x: c.x + inner, y: c.y - inner),
            CGPoint(x: c.x + r, y: c.y),
            CGPoint(x: c.x + inner, y: c.y + inner),
            CGPoint(x: c.x, y: c.y + r),
            CGPoint(x: c.x - inner, y: c.y + inner),
            CGPoint(x: c.x - r, y: c.y),
            CGPoint(x: c.x - inner, y: c.y - inner)
        ]
        var p = Path()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}

/// The composed Forge mark: anvil + strike spark above the face.
struct ForgeGlyph: View {
    var color: Color = .white

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack(alignment: .topLeading) {
                AnvilShape()
                    .fill(color)
                StrikeSparkShape()
                    .fill(color)
                    .frame(width: s * 0.22, height: s * 0.22)
                    .offset(x: s * 0.60, y: -s * 0.01)
            }
            .frame(width: s, height: s)
        }
    }
}

// MARK: - Brand Mark (icon tile)

/// A quiet rounded tile containing the product's SF Symbol. The app mark (.forge) is
/// the one accent-filled tile, carrying the custom anvil-and-spark glyph.
struct BrandMark: View {
    let kind: BrandMarkKind
    var size: CGFloat = 40
    var dimmed: Bool = false

    private var isAppMark: Bool { kind == .forge }

    var body: some View {
        ZStack {
            if isAppMark {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Theme.accent)
                ForgeGlyph()
                    .padding(size * 0.16)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Theme.surfaceHi)
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Theme.textSec)
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.5 : 1)
    }
}

// MARK: - App Wordmark

/// The masthead: the anvil mark plus "Forge" as a proper title over everything below.
struct AppWordmark: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            BrandMark(kind: .forge, size: compact ? 24 : 30)
            Text("Forge")
                .scaledFont(compact ? 15 : 19, weight: .semibold)
                .foregroundStyle(Theme.textPri)
        }
    }
}
