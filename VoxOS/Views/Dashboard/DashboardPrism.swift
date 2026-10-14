import SwiftUI

/// The Dashboard's signature: the last seven days of dictation enter from the left as one white
/// waveform, pass through a prism, and leave on the right as bands in each mode's colour, each
/// band as thick as that mode's share of the week's words. With nothing dictated this week it is
/// a calm flat beam and a single muted ray.
struct DashboardPrism: View {
    let days: [DashboardProductivityPoint]
    let shares: [DashboardModeShare]
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat = 0

    var body: some View {
        let bands = resolvedBands
        let showsData = isActive && !bands.isEmpty

        VStack(alignment: .leading, spacing: 10) {
            DashboardPrismCanvas(
                envelope: showsData ? envelope : [],
                bands: showsData ? bands : []
            )
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle()
                        .frame(width: geometry.size.width * reveal)
                }
            }
            .accessibilityHidden(true)

            if showsData {
                legend(bands)
            }
        }
        .onAppear(perform: startReveal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 7 days of dictation, split by mode")
        .accessibilityValue(accessibilityValue(bands, showsData: showsData))
    }

    private func startReveal() {
        guard reveal < 1 else { return }
        if reduceMotion {
            reveal = 1
        } else {
            withAnimation(.easeOut(duration: 0.6)) {
                reveal = 1
            }
        }
    }

    /// Each day's words as 0...1, square-rooted so a light day still shows next to a heavy one.
    private var envelope: [Double] {
        let maxWords = Double(max(days.map(\.words).max() ?? 0, 1))
        return days.map { (Double($0.words) / maxWords).squareRoot() }
    }

    /// Bands by share of words; when every session has zero words, by share of sessions.
    private var resolvedBands: [DashboardPrismBand] {
        let totalWords = shares.reduce(0) { $0 + $1.words }
        let totalSessions = shares.reduce(0) { $0 + $1.sessionCount }
        let useWords = totalWords > 0
        let total = Double(useWords ? totalWords : totalSessions)
        guard total > 0 else { return [] }

        return shares.compactMap { share in
            let value = Double(useWords ? share.words : share.sessionCount)
            guard value > 0 else { return nil }
            return DashboardPrismBand(
                id: share.id,
                name: share.modeName ?? String(localized: "Dictation"),
                color: ModeSpectrum.color(forModeNamed: share.modeName),
                share: value / total
            )
        }
    }

    private func legend(_ bands: [DashboardPrismBand]) -> some View {
        ViewThatFits(in: .horizontal) {
            legendRow(bands, limit: 4)
            legendRow(bands, limit: 3)
            legendRow(bands, limit: 2)
            legendRow(bands, limit: 1)
        }
    }

    private func legendRow(_ bands: [DashboardPrismBand], limit: Int) -> some View {
        HStack(spacing: 14) {
            ForEach(bands.prefix(limit)) { band in
                HStack(spacing: 6) {
                    Circle()
                        .fill(band.color)
                        .frame(width: 6, height: 6)
                    Text(verbatim: band.name)
                        .font(.app(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondary)
                    Text(verbatim: Self.percentText(band.share))
                        .font(.appMono(size: 11, weight: .regular))
                        .foregroundStyle(AppTheme.Text.muted)
                }
                .lineLimit(1)
                .fixedSize()
            }
            if bands.count > limit {
                Text(verbatim: "+\(bands.count - limit)")
                    .font(.appMono(size: 11, weight: .regular))
                    .foregroundStyle(AppTheme.Text.muted)
                    .fixedSize()
            }
        }
    }

    private func accessibilityValue(_ bands: [DashboardPrismBand], showsData: Bool) -> String {
        guard showsData else { return String(localized: "Nothing dictated in the last 7 days") }
        return
            bands
            .map { "\($0.name) \(Self.percentText($0.share))" }
            .joined(separator: ", ")
    }

    private static func percentText(_ share: Double) -> String {
        let percent = share * 100
        if percent > 0 && percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }
}

struct DashboardPrismBand: Identifiable {
    let id: String
    let name: String
    let color: Color
    let share: Double
}

/// The drawing itself. Pure geometry from the size it is given, so it scales from the narrow
/// stacked hero to the wide one without separate layouts.
private struct DashboardPrismCanvas: View {
    private static let minimumBandThickness: CGFloat = 3
    private static let bandGap: CGFloat = 1.5

    let envelope: [Double]
    let bands: [DashboardPrismBand]

    var body: some View {
        Canvas { context, size in
            let geometry = Geometry(size: size)
            drawPrism(in: &context, geometry: geometry)
            drawWave(in: &context, geometry: geometry)
            drawBands(in: &context, geometry: geometry)
        }
    }

    private struct Geometry {
        let size: CGSize
        let mid: CGFloat
        let side: CGFloat
        let apex: CGPoint
        let bottomLeft: CGPoint
        let bottomRight: CGPoint
        /// Where the beam meets the left face and leaves the right face: each face's midpoint,
        /// which sits on the vertical centre line.
        let entry: CGPoint
        let exit: CGPoint

        init(size: CGSize) {
            self.size = size
            mid = size.height / 2
            let height = min(size.height * 0.62, size.width * 0.3)
            side = height / (3.0.squareRoot() / 2)
            let centreX = size.width * 0.44
            apex = CGPoint(x: centreX, y: mid - height / 2)
            bottomLeft = CGPoint(x: centreX - side / 2, y: mid + height / 2)
            bottomRight = CGPoint(x: centreX + side / 2, y: mid + height / 2)
            entry = CGPoint(x: centreX - side / 4, y: mid)
            exit = CGPoint(x: centreX + side / 4, y: mid)
        }
    }

    private func drawPrism(in context: inout GraphicsContext, geometry: Geometry) {
        var triangle = Path()
        triangle.move(to: geometry.apex)
        triangle.addLine(to: geometry.bottomRight)
        triangle.addLine(to: geometry.bottomLeft)
        triangle.closeSubpath()

        context.fill(triangle, with: .color(AppTheme.Text.primary.opacity(0.04)))
        context.stroke(
            triangle,
            with: .color(AppTheme.Text.secondary.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.2, lineJoin: .round)
        )

        var inside = Path()
        inside.move(to: geometry.entry)
        inside.addLine(to: geometry.exit)
        context.stroke(
            inside,
            with: .color(AppTheme.Text.primary.opacity(envelope.isEmpty ? 0.2 : 0.45)),
            lineWidth: 1
        )
    }

    /// The week as a voice waveform: the envelope follows each day's words, the carrier is a
    /// fixed oscillation, and it narrows to a point where it meets the prism.
    private func drawWave(in context: inout GraphicsContext, geometry: Geometry) {
        let length = geometry.entry.x
        guard length > 4 else { return }

        guard !envelope.isEmpty else {
            var flat = Path()
            flat.move(to: CGPoint(x: 0, y: geometry.mid))
            flat.addLine(to: geometry.entry)
            context.stroke(flat, with: .color(AppTheme.Text.primary.opacity(0.3)), lineWidth: 1.2)
            return
        }

        let maxAmplitude = geometry.size.height * 0.42
        let cycles = Double(max(envelope.count, 1)) * 2.4
        let steps = max(Int(length / 1.5), 24)
        var wave = Path()

        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let taper = min(1, (1 - t) * 5)
            let level = 0.12 + 0.88 * envelopeLevel(at: t)
            let carrier = sin(2 * .pi * cycles * t) * 0.75 + sin(2 * .pi * cycles * 2.3 * t + 0.6) * 0.25
            let y = geometry.mid - CGFloat(carrier * level * taper) * maxAmplitude
            let point = CGPoint(x: CGFloat(t) * length, y: y)
            if step == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
        }

        context.stroke(
            wave,
            with: .color(AppTheme.Text.primary.opacity(0.92)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )
    }

    /// The envelope at 0...1 along the beam, eased between days so the wave swells rather than steps.
    private func envelopeLevel(at t: Double) -> Double {
        guard envelope.count > 1 else { return envelope.first ?? 0 }
        let position = t * Double(envelope.count - 1)
        let index = min(Int(position), envelope.count - 2)
        let fraction = position - Double(index)
        let eased = fraction * fraction * (3 - 2 * fraction)
        return envelope[index] + (envelope[index + 1] - envelope[index]) * eased
    }

    private func drawBands(in context: inout GraphicsContext, geometry: Geometry) {
        let start = geometry.exit
        let endX = geometry.size.width
        let length = endX - start.x
        guard length > 4 else { return }

        guard !bands.isEmpty else {
            var ray = Path()
            ray.move(to: start)
            ray.addLine(to: CGPoint(x: endX, y: geometry.mid))
            context.stroke(ray, with: .color(AppTheme.Text.muted.opacity(0.6)), lineWidth: 1.2)
            return
        }

        let gaps = Self.bandGap * CGFloat(bands.count - 1)
        let fanHeight = geometry.size.height * 0.88 - gaps
        let startHeight = min(CGFloat(bands.count) * 1.5 + 2, geometry.size.height * 0.12)

        // A small mode still gets a visible band; the rest are scaled to fit.
        let raw = bands.map { max(CGFloat($0.share) * fanHeight, Self.minimumBandThickness) }
        let scale = fanHeight / max(raw.reduce(0, +), 1)
        let thicknesses = raw.map { $0 * scale }

        var endTop = geometry.mid - (fanHeight + gaps) / 2
        var startTop = geometry.mid - startHeight / 2

        for (index, band) in bands.enumerated() {
            let endBottom = endTop + thicknesses[index]
            let startBottom = startTop + startHeight * CGFloat(band.share)

            var path = Path()
            path.move(to: CGPoint(x: start.x, y: startTop))
            path.addCurve(
                to: CGPoint(x: endX, y: endTop),
                control1: CGPoint(x: start.x + length * 0.45, y: startTop),
                control2: CGPoint(x: start.x + length * 0.55, y: endTop)
            )
            path.addLine(to: CGPoint(x: endX, y: endBottom))
            path.addCurve(
                to: CGPoint(x: start.x, y: startBottom),
                control1: CGPoint(x: start.x + length * 0.55, y: endBottom),
                control2: CGPoint(x: start.x + length * 0.45, y: startBottom)
            )
            path.closeSubpath()

            context.fill(path, with: .color(band.color.opacity(0.88)))

            endTop = endBottom + Self.bandGap
            startTop = startBottom
        }
    }
}
