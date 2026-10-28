import SwiftUI

// MARK: - Weather page

/// The weather as a small moving scene beside the numbers: a sun (or a moon) for clear skies,
/// clouds drifting over it, rain or snow falling, lightning in a storm.
///
/// The scene is drawn in one Canvas at 30 frames a second, and only while the page is on screen:
/// leaving the page removes the view, and with it the animation. Reduce Motion draws it still.
struct NotchWeatherPage: View {
    @ObservedObject var today: NotchToday

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            if let weather = today.weather {
                NotchWeatherScene(kind: weather.kind, isDay: weather.isDay ?? Self.isDaytime(Date()))
                    .frame(width: 150, height: NotchHome.Card.coverSize)
                    .accessibilityLabel(Text(verbatim: weather.conditions))
                details(weather)
            } else {
                NotchWeatherScene(kind: .partlyCloudy, isDay: Self.isDaytime(Date()))
                    .frame(width: 150, height: NotchHome.Card.coverSize)
                    .opacity(0.5)
                Text("Weather shows once it has been fetched")
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, NotchHome.Card.top)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear { today.refresh() }
    }

    private func details(_ weather: NotchToday.Weather) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(weather.temperature)°")
                .font(.app(size: 36, weight: .semibold))
                .foregroundStyle(.white)
            Text(verbatim: weather.conditions.prefix(1).uppercased() + weather.conditions.dropFirst())
                .font(.app(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            if let high = weather.high, let low = weather.low {
                Text(verbatim: "H \(high)°  ·  L \(low)°")
                    .font(.app(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if let place = weather.place {
                Text(verbatim: place)
                    .font(.app(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
    }

    /// When the service does not say, the local clock decides between sun and moon.
    nonisolated static func isDaytime(_ date: Date, calendar: Calendar = .current) -> Bool {
        (6..<19).contains(calendar.component(.hour, from: date))
    }
}

// MARK: - Scene

struct NotchWeatherScene: View {
    let kind: NotchToday.Weather.Kind
    let isDay: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A still frame when motion is reduced, from a fixed moment so it looks the same each time.
    private static let stillTime: TimeInterval = 12.3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Canvas { canvas, size in
                let time = reduceMotion ? Self.stillTime : context.date.timeIntervalSinceReferenceDate
                NotchWeatherPainter(kind: kind, isDay: isDay, time: time, size: size).paint(&canvas)
            }
        }
        .background(LinearGradient(colors: sky, startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    private var sky: [Color] {
        func rgb(_ hex: UInt32) -> Color {
            Color(
                red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255)
        }
        switch (kind, isDay) {
        case (.clear, true): return [rgb(0x2F7BEA), rgb(0x8EC5FF)]
        case (.partlyCloudy, true): return [rgb(0x3C82D8), rgb(0xA4C6EA)]
        case (.clear, false), (.partlyCloudy, false): return [rgb(0x0A1633), rgb(0x24335E)]
        case (.cloudy, _): return [rgb(0x4E5866), rgb(0x8992A0)]
        case (.fog, _): return [rgb(0x6E7782), rgb(0xB0B7C1)]
        case (.rain, _): return [rgb(0x26303E), rgb(0x4C5869)]
        case (.snow, _): return [rgb(0x5D6E84), rgb(0xB4C2D3)]
        case (.thunder, _): return [rgb(0x15172A), rgb(0x343A52)]
        }
    }
}

/// Draws one frame. Every position comes from the time and a fixed per-item seed, so nothing is
/// stored between frames.
private struct NotchWeatherPainter {
    let kind: NotchToday.Weather.Kind
    let isDay: Bool
    let time: TimeInterval
    let size: CGSize

    private var width: CGFloat { size.width }
    private var height: CGFloat { size.height }
    private var unit: CGFloat { min(width, height) }

    /// 0..<1, the same for the same seed.
    private func random(_ seed: Int, _ salt: Double = 0) -> CGFloat {
        let value = sin(Double(seed) * 12.9898 + salt * 78.233) * 43758.5453
        return CGFloat(value - value.rounded(.down))
    }

    func paint(_ canvas: inout GraphicsContext) {
        switch kind {
        case .clear:
            isDay ? sun(&canvas, at: CGPoint(x: width * 0.5, y: height * 0.46)) : night(&canvas)
        case .partlyCloudy:
            if isDay { sun(&canvas, at: CGPoint(x: width * 0.62, y: height * 0.38)) } else { night(&canvas) }
            clouds(&canvas, count: 2, shade: 1, alpha: 0.95, lane: 0.55)
        case .cloudy:
            clouds(&canvas, count: 3, shade: 0.9, alpha: 0.9, lane: 0.45)
        case .fog:
            fog(&canvas)
        case .rain:
            clouds(&canvas, count: 3, shade: 0.7, alpha: 0.95, lane: 0.3)
            rain(&canvas, drops: 30)
        case .snow:
            clouds(&canvas, count: 3, shade: 0.92, alpha: 0.9, lane: 0.3)
            snow(&canvas)
        case .thunder:
            clouds(&canvas, count: 3, shade: 0.45, alpha: 0.98, lane: 0.3)
            rain(&canvas, drops: 36)
            lightning(&canvas)
        }
    }

    // MARK: Sun, moon, stars

    private func sun(_ canvas: inout GraphicsContext, at center: CGPoint) {
        let radius = unit * 0.17
        let pulse = 0.32 + 0.08 * sin(time * 1.4)
        let glow = Path(
            ellipseIn: CGRect(
                x: center.x - radius * 2.3, y: center.y - radius * 2.3, width: radius * 4.6, height: radius * 4.6))
        canvas.fill(
            glow,
            with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.4).opacity(pulse), .clear]), center: center,
                startRadius: radius * 0.8, endRadius: radius * 2.3))
        // Rays, turning slowly.
        let rays = 10
        for index in 0..<rays {
            let angle = Double(index) / Double(rays) * 2 * .pi + time * 0.25
            var ray = Path()
            ray.move(to: CGPoint(x: center.x + cos(angle) * radius * 1.35, y: center.y + sin(angle) * radius * 1.35))
            ray.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 1.8, y: center.y + sin(angle) * radius * 1.8))
            canvas.stroke(
                ray, with: .color(Color(red: 1, green: 0.85, blue: 0.35).opacity(0.85)),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        canvas.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.93, blue: 0.55), Color(red: 1, green: 0.74, blue: 0.2)]),
                startPoint: CGPoint(x: center.x, y: center.y - radius),
                endPoint: CGPoint(x: center.x, y: center.y + radius)))
    }

    private func night(_ canvas: inout GraphicsContext) {
        for index in 0..<14 {
            let point = CGPoint(x: random(index) * width, y: random(index, 1) * height * 0.75)
            let twinkle = 0.35 + 0.45 * (0.5 + 0.5 * sin(time * (1.2 + Double(random(index, 2)) * 2) + Double(index)))
            let dot = 0.8 + random(index, 3) * 1.1
            canvas.fill(
                Path(ellipseIn: CGRect(x: point.x, y: point.y, width: dot, height: dot)),
                with: .color(.white.opacity(twinkle)))
        }
        // A crescent: the moon with a circle up and to its right cut away.
        let radius = unit * 0.16
        let center = CGPoint(x: width * 0.62, y: height * 0.38)
        var moon = canvas
        moon.clip(
            to: Path(
                ellipseIn: CGRect(
                    x: center.x + radius * 0.5 - radius * 0.95, y: center.y - radius * 0.3 - radius * 0.95,
                    width: radius * 1.9, height: radius * 1.9)),
            options: .inverse)
        moon.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .color(Color(red: 0.98, green: 0.95, blue: 0.82)))
    }

    // MARK: Clouds, fog

    private func cloud(_ canvas: inout GraphicsContext, center: CGPoint, scale: CGFloat, color: Color) {
        let base = unit * 0.2 * scale
        var shape = Path(
            roundedRect: CGRect(
                x: center.x - base * 1.6, y: center.y - base * 0.2, width: base * 3.2, height: base * 0.9),
            cornerRadius: base * 0.45)
        shape.addEllipse(
            in: CGRect(x: center.x - base * 1.25, y: center.y - base * 0.75, width: base * 1.3, height: base * 1.3))
        shape.addEllipse(
            in: CGRect(x: center.x - base * 0.45, y: center.y - base * 1.15, width: base * 1.6, height: base * 1.6))
        shape.addEllipse(
            in: CGRect(x: center.x + base * 0.45, y: center.y - base * 0.65, width: base * 1.15, height: base * 1.15))
        canvas.fill(shape, with: .color(color))
    }

    /// Clouds drifting left to right at their own pace, coming round again past the edge.
    private func clouds(_ canvas: inout GraphicsContext, count: Int, shade: Double, alpha: Double, lane: CGFloat) {
        for index in 0..<count {
            let scale = 0.85 + random(index, 4) * 0.5
            let span = width + unit * 0.9 * scale
            let speed = 6 + Double(random(index, 5)) * 6
            let x =
                (random(index, 6) * span + CGFloat(time * speed)).truncatingRemainder(dividingBy: span) - unit * 0.45
                * scale
            let y = height * (lane - 0.1 + random(index, 7) * 0.22)
            let tone = shade - Double(index) * 0.06
            cloud(&canvas, center: CGPoint(x: x, y: y), scale: scale, color: Color(white: tone).opacity(alpha))
        }
    }

    private func fog(_ canvas: inout GraphicsContext) {
        for index in 0..<4 {
            let y = height * (0.25 + CGFloat(index) * 0.18)
            let drift = sin(time * 0.4 + Double(index) * 1.3) * Double(width) * 0.12
            let band = Path(
                roundedRect: CGRect(x: CGFloat(drift) - width * 0.1, y: y, width: width * 1.2, height: unit * 0.1),
                cornerRadius: unit * 0.05)
            canvas.fill(band, with: .color(.white.opacity(0.22 + Double(random(index, 8)) * 0.15)))
        }
    }

    // MARK: Rain, snow, lightning

    private func rain(_ canvas: inout GraphicsContext, drops: Int) {
        let top = height * 0.38
        let fall = height - top + 10
        for index in 0..<drops {
            let speed = 70 + Double(random(index, 9)) * 50
            let y = top + (random(index, 10) * fall + CGFloat(time * speed)).truncatingRemainder(dividingBy: fall) - 6
            let x = random(index, 11) * width
            var drop = Path()
            drop.move(to: CGPoint(x: x, y: y))
            drop.addLine(to: CGPoint(x: x - 1.6, y: y + 7))
            canvas.stroke(
                drop, with: .color(Color(red: 0.7, green: 0.82, blue: 1).opacity(0.75)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }

    private func snow(_ canvas: inout GraphicsContext) {
        let top = height * 0.35
        let fall = height - top + 6
        for index in 0..<24 {
            let speed = 12 + Double(random(index, 12)) * 12
            let y = top + (random(index, 13) * fall + CGFloat(time * speed)).truncatingRemainder(dividingBy: fall) - 3
            let sway = sin(time * 1.3 + Double(index)) * 3
            let x = random(index, 14) * width + CGFloat(sway)
            let dot = 1.6 + random(index, 15) * 1.6
            canvas.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)), with: .color(.white.opacity(0.9)))
        }
    }

    /// A strike every few seconds: two quick flashes of the sky and a bolt.
    private func lightning(_ canvas: inout GraphicsContext) {
        let period = 3.4
        let phase = time.truncatingRemainder(dividingBy: period) / period
        let flash = phase < 0.03 || (phase > 0.06 && phase < 0.1)
        guard flash else { return }
        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.28)))
        let start = CGPoint(x: width * (0.35 + random(Int(time / period), 16) * 0.3), y: height * 0.35)
        var bolt = Path()
        bolt.move(to: start)
        bolt.addLine(to: CGPoint(x: start.x - unit * 0.08, y: start.y + unit * 0.22))
        bolt.addLine(to: CGPoint(x: start.x + unit * 0.02, y: start.y + unit * 0.22))
        bolt.addLine(to: CGPoint(x: start.x - unit * 0.07, y: start.y + unit * 0.48))
        canvas.stroke(
            bolt, with: .color(Color(red: 1, green: 0.97, blue: 0.75)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
    }
}
