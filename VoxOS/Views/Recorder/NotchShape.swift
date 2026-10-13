import SwiftUI

/// The notch silhouette: a flat top that meets the screen edge, scooped shoulders just below it,
/// straight sides, and rounded bottom corners.
///
/// Shoulders and corners are true circular arcs. A quadratic curve gives a slightly pinched,
/// "drawn" corner; a circle is what makes the band look machined into the display.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 20) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    init(_ radii: NotchDesign.Radii) {
        self.init(topCornerRadius: radii.shoulder, bottomCornerRadius: radii.bottom)
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    private static let arcSteps = 12

    func path(in rect: CGRect) -> Path {
        // A shape narrower or shorter than its own corners would fold over itself, so the radii
        // are limited to what fits. This also keeps the animation sane at zero size.
        let shoulder = max(0, min(topCornerRadius, rect.width / 2, rect.height))
        let bottom = max(0, min(bottomCornerRadius, (rect.width - shoulder * 2) / 2, rect.height - shoulder))

        var path = Path()
        let steps = Self.arcSteps

        // Top edge, left to right.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // Right shoulder: a quarter circle scooped out of the corner, centred on the screen edge.
        if shoulder > 0 {
            let center = CGPoint(x: rect.maxX, y: rect.minY + shoulder)
            for step in 1...steps {
                let angle = -CGFloat.pi / 2 - CGFloat(step) / CGFloat(steps) * (CGFloat.pi / 2)
                path.addLine(
                    to: CGPoint(x: center.x + shoulder * cos(angle), y: center.y + shoulder * sin(angle)))
            }
        }

        // Right side down to the bottom-right corner.
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - bottom))

        // Bottom-right corner, convex.
        if bottom > 0 {
            let center = CGPoint(x: rect.maxX - shoulder - bottom, y: rect.maxY - bottom)
            for step in 1...steps {
                let angle = CGFloat(step) / CGFloat(steps) * (CGFloat.pi / 2)
                path.addLine(to: CGPoint(x: center.x + bottom * cos(angle), y: center.y + bottom * sin(angle)))
            }
        }

        // Bottom edge, then the bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + shoulder + bottom, y: rect.maxY))
        if bottom > 0 {
            let center = CGPoint(x: rect.minX + shoulder + bottom, y: rect.maxY - bottom)
            for step in 1...steps {
                let angle = CGFloat.pi / 2 + CGFloat(step) / CGFloat(steps) * (CGFloat.pi / 2)
                path.addLine(to: CGPoint(x: center.x + bottom * cos(angle), y: center.y + bottom * sin(angle)))
            }
        }

        // Left side up, then the left shoulder back to the start.
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder))
        if shoulder > 0 {
            let center = CGPoint(x: rect.minX, y: rect.minY + shoulder)
            for step in 1...steps {
                let angle = -CGFloat(step) / CGFloat(steps) * (CGFloat.pi / 2)
                path.addLine(
                    to: CGPoint(x: center.x + shoulder * cos(angle), y: center.y + shoulder * sin(angle)))
            }
        }

        path.closeSubpath()
        return path
    }
}
