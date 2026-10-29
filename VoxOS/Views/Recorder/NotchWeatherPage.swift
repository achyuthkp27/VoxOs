import SwiftUI

// MARK: - Weather page

/// The weather as a page of numbers, read top to bottom: where and as of when; the temperature with
/// the conditions and today's range; four readings in fixed places (rain, humidity, feels like,
/// wind); and the next days, each with its chance of rain and its range as a bar on the week's.
///
/// Nothing on it moves or polls: it changes when `NotchToday` fetches a new reading (at most every
/// half hour, and on opening the page once the last one is older than that).
struct NotchWeatherPage: View {
    @ObservedObject var today: NotchToday

    /// What "Today" is judged against; passed in so a preview or test can pick any day.
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let weather = today.weather {
                header(weather)
                    .padding(.bottom, Layout.headerSpacing)
                current(weather)
                    .padding(.bottom, Layout.sectionSpacing)
                readings(weather)
                    .padding(.bottom, Layout.sectionSpacing)
                forecast(weather)
            } else {
                Text("Weather shows once it has been fetched")
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, NotchHome.Card.top + 4)
        .padding(.horizontal, AgentComposer.panelInset + 6)
        .padding(.bottom, NotchHome.Card.bottom)
        .foregroundStyle(.white)
        .onAppear { today.refresh() }
    }

    /// The card's height on this page: everything above, at its fixed size, whatever came back.
    static var cardHeight: CGFloat {
        let insets: CGFloat = NotchHome.Card.top + 4 + NotchHome.Card.bottom + 6
        let top: CGFloat = Layout.headerHeight + Layout.headerSpacing + Layout.currentHeight
        let middle: CGFloat = Layout.sectionSpacing + Layout.readingsHeight + Layout.sectionSpacing
        return insets + top + middle + Layout.forecastHeight
    }

    enum Layout {
        static let headerHeight: CGFloat = 18
        static let headerSpacing: CGFloat = 8
        static let currentHeight: CGFloat = 46
        static let sectionSpacing: CGFloat = 10
        static let readingsHeight: CGFloat = 32
        static let rowHeight: CGFloat = 22
        static let rowSpacing: CGFloat = 2
        static var forecastHeight: CGFloat {
            CGFloat(NotchToday.forecastDays) * rowHeight + CGFloat(NotchToday.forecastDays - 1) * rowSpacing
        }
        static let dayWidth: CGFloat = 54
        static let symbolWidth: CGFloat = 24
        static let chanceWidth: CGFloat = 40
        static let temperatureWidth: CGFloat = 34
        static let barHeight: CGFloat = 4
        static let barSpacing: CGFloat = 8
    }

    // MARK: Header

    private func header(_ weather: NotchToday.Weather) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: weather.place.flatMap(Self.city) ?? String(localized: "Weather"))
                .font(.app(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            if let readAt = weather.readAt {
                // "as of", never "now": a reading can be half an hour old.
                Text("as of \(readAt.formatted(date: .omitted, time: .shortened))")
                    .font(.app(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Layout.headerHeight)
    }

    /// The place's first part, "Bengaluru" from "Bengaluru, Karnataka, India": the region and the
    /// country take the line and say nothing a person checking the weather needs.
    nonisolated static func city(_ place: String) -> String? {
        let first = place.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return first?.isEmpty == false ? first : nil
    }

    // MARK: Now

    private func current(_ weather: NotchToday.Weather) -> some View {
        let celsius = weather.temperatureC ?? Double(weather.temperature)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: weather.symbol)
                .font(.app(size: 28, weight: .medium))
                .symbolRenderingMode(.multicolor)
                .frame(width: 38)
            Text(verbatim: NotchWeatherFormat.temperature(celsius))
                .font(.app(size: 38, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: weather.conditions.prefix(1).uppercased() + weather.conditions.dropFirst())
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if let high = weather.days.first?.highC ?? weather.high.map(Double.init),
                    let low = weather.days.first?.lowC ?? weather.low.map(Double.init)
                {
                    Text(verbatim: NotchWeatherFormat.range(high: high, low: low))
                        .font(.app(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Layout.currentHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(weather.conditions), \(NotchWeatherFormat.temperature(celsius))"))
    }

    // MARK: Readings

    /// Four readings in fixed places; one the service did not give is a dash, so the row reads the
    /// same way every time.
    private func readings(_ weather: NotchToday.Weather) -> some View {
        HStack(spacing: 0) {
            reading(String(localized: "Rain"), weather.rainChance.map { NotchWeatherFormat.percent($0) })
            reading(String(localized: "Humidity"), weather.humidity.map { NotchWeatherFormat.percent($0) })
            reading(String(localized: "Feels like"), weather.feelsLikeC.map { NotchWeatherFormat.temperature($0) })
            reading(String(localized: "Wind"), weather.windKPH.map { NotchWeatherFormat.wind($0) })
        }
        .frame(height: Layout.readingsHeight)
    }

    private func reading(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .font(.app(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: value ?? "—")
                .font(.app(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Days

    /// Always the same number of rows, empty ones when fewer days came back, so the card keeps the
    /// height it opened at.
    private func forecast(_ weather: NotchToday.Weather) -> some View {
        let days = Array(weather.days.prefix(NotchToday.forecastDays))
        let bounds = NotchWeatherRange.bounds(of: days)
        return VStack(spacing: Layout.rowSpacing) {
            ForEach(0..<NotchToday.forecastDays, id: \.self) { index in
                if index < days.count, let bounds {
                    dayRow(days[index], bounds: bounds, current: weather.temperatureC)
                } else {
                    Color.clear.frame(height: Layout.rowHeight)
                }
            }
        }
        .frame(height: Layout.forecastHeight, alignment: .top)
    }

    private func dayRow(_ day: NotchToday.Weather.Day, bounds: ClosedRange<Double>, current: Double?) -> some View {
        let isToday = Calendar.current.isDate(day.date, inSameDayAs: now)
        let segment = NotchWeatherRange.segment(low: day.lowC, high: day.highC, in: bounds)
        // Only today's bar has the current temperature on it: on any other day it has not happened.
        let mark = isToday ? current.map { NotchWeatherRange.position($0, within: segment, in: bounds) } : nil
        return HStack(spacing: 0) {
            Text(verbatim: isToday ? String(localized: "Today") : day.date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: Layout.dayWidth, alignment: .leading)
            Image(systemName: day.symbol)
                .font(.app(size: 12, weight: .medium))
                .symbolRenderingMode(.multicolor)
                .frame(width: Layout.symbolWidth)
            // Printed only where it is worth reading: a column of "0%" down dry days says nothing.
            Text(verbatim: day.rainChance.flatMap { $0 >= 10 ? NotchWeatherFormat.percent($0) : nil } ?? "")
                .font(.app(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchWeatherScale.rainBlue)
                .frame(width: Layout.chanceWidth, alignment: .trailing)
            Text(verbatim: NotchWeatherFormat.temperature(day.lowC))
                .font(.app(size: 12))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: Layout.temperatureWidth, alignment: .trailing)
            NotchWeatherBar(low: day.lowC, high: day.highC, segment: segment, mark: mark)
                .frame(height: Layout.barHeight)
                .padding(.horizontal, Layout.barSpacing)
            Text(verbatim: NotchWeatherFormat.temperature(day.highC))
                .font(.app(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(width: Layout.temperatureWidth, alignment: .leading)
        }
        .frame(height: Layout.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken(day, isToday: isToday)))
    }

    private func spoken(_ day: NotchToday.Weather.Day, isToday: Bool) -> String {
        var parts = [
            isToday ? String(localized: "Today") : day.date.formatted(.dateTime.weekday(.wide)), day.conditions,
        ]
        if let chance = day.rainChance, chance >= 10 {
            parts.append(String(localized: "\(NotchWeatherFormat.percent(chance)) chance of rain"))
        }
        parts.append(NotchWeatherFormat.range(high: day.highC, low: day.lowC))
        return parts.joined(separator: ", ")
    }
}

// MARK: - Range bar

/// One day's range on the week's track, in the colours of the temperatures it covers, with a white
/// dot for the temperature now on today's.
private struct NotchWeatherBar: View {
    let low: Double
    let high: Double
    let segment: (start: Double, length: Double)
    let mark: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                LinearGradient(
                    stops: NotchWeatherScale.gradient(from: low, to: high).map {
                        Gradient.Stop(color: $0.color, location: $0.location)
                    }, startPoint: .leading, endPoint: .trailing
                )
                .frame(width: max(height, width * segment.length))
                .clipShape(Capsule())
                .offset(x: width * segment.start)
                if let mark {
                    // White on a black ring, so it shows on the pale end of the scale too.
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .background(Circle().fill(.black).frame(width: 9, height: 9))
                        .offset(x: min(max(width * mark - 3, 0), width - 6))
                }
            }
            .frame(width: width, height: height)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Arithmetic

/// Where a day's range sits on the week's, as fractions of the bar, so the view multiplies by
/// whatever width it has. Pure, for the tests.
enum NotchWeatherRange {
    /// The coldest low to the warmest high of the days shown; nil for none.
    static func bounds(of days: [NotchToday.Weather.Day]) -> ClosedRange<Double>? {
        guard let coldest = days.map(\.lowC).min(), let warmest = days.map(\.highC).max(), coldest <= warmest
        else { return nil }
        return coldest...warmest
    }

    /// Start and length, each 0…1. A week with no spread draws every day full; a day whose low is
    /// its high still gets a sliver rather than vanishing.
    static func segment(low: Double, high: Double, in bounds: ClosedRange<Double>) -> (start: Double, length: Double) {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return (0, 1) }
        let start = min(max((min(low, high) - bounds.lowerBound) / span, 0), 1)
        let end = min(max((max(low, high) - bounds.lowerBound) / span, 0), 1)
        return (start, min(max(end - start, 0.04), 1 - start))
    }

    /// The temperature now on the bar, 0…1, kept on today's own segment: the current reading and the
    /// day's forecast are separate answers and can disagree by a degree.
    static func position(
        _ value: Double, within segment: (start: Double, length: Double), in bounds: ClosedRange<Double>
    )
        -> Double
    {
        let span = bounds.upperBound - bounds.lowerBound
        let raw = span > 0 ? (value - bounds.lowerBound) / span : 0.5
        return min(max(raw, segment.start), segment.start + segment.length)
    }
}

/// The colour of a temperature: a fixed scale of degrees, not the week's own spread, so a cold week
/// reads blue and a hot one orange.
enum NotchWeatherScale {
    struct Stop {
        let celsius: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    static let stops: [Stop] = [
        Stop(celsius: -12, red: 0.58, green: 0.48, blue: 1.00),
        Stop(celsius: 0, red: 0.32, green: 0.60, blue: 1.00),
        Stop(celsius: 10, red: 0.30, green: 0.80, blue: 0.84),
        Stop(celsius: 17, red: 0.58, green: 0.84, blue: 0.36),
        Stop(celsius: 23, red: 1.00, green: 0.80, blue: 0.24),
        Stop(celsius: 30, red: 0.98, green: 0.55, blue: 0.18),
        Stop(celsius: 38, red: 0.94, green: 0.30, blue: 0.22),
    ]

    /// The blue a chance of rain is printed in, the blue of the drops beside it.
    static let rainBlue = Color(.sRGB, red: 0.40, green: 0.76, blue: 1.0)

    static func components(atCelsius celsius: Double) -> (red: Double, green: Double, blue: Double) {
        guard let first = stops.first, let last = stops.last else { return (1, 1, 1) }
        if !celsius.isFinite || celsius <= first.celsius { return (first.red, first.green, first.blue) }
        if celsius >= last.celsius { return (last.red, last.green, last.blue) }
        for (lower, upper) in zip(stops, stops.dropFirst()) where celsius <= upper.celsius {
            let t = (celsius - lower.celsius) / (upper.celsius - lower.celsius)
            return (
                lower.red + (upper.red - lower.red) * t, lower.green + (upper.green - lower.green) * t,
                lower.blue + (upper.blue - lower.blue) * t
            )
        }
        return (last.red, last.green, last.blue)
    }

    /// The gradient across one bar from `low` to `high` °C, bending at every scale stop in between.
    static func gradient(from low: Double, to high: Double) -> [(location: Double, color: Color)] {
        func color(_ celsius: Double) -> Color {
            let value = components(atCelsius: celsius)
            return Color(.sRGB, red: value.red, green: value.green, blue: value.blue)
        }
        let from = min(low, high)
        let to = max(low, high)
        guard to > from else { return [(0, color(from)), (1, color(from))] }
        let inner = stops.filter { $0.celsius > from && $0.celsius < to }.map {
            (location: ($0.celsius - from) / (to - from), color: color($0.celsius))
        }
        return [(0, color(from))] + inner + [(1, color(to))]
    }
}

/// Temperatures, percentages and wind as the reader's region writes them: °F and mph in the US,
/// °C and km/h elsewhere (mph in the UK too).
enum NotchWeatherFormat {
    static func usesFahrenheit(_ locale: Locale = .current) -> Bool { locale.measurementSystem == .us }

    /// "19°", rounded half away from zero.
    static func temperature(_ celsius: Double, locale: Locale = .current) -> String {
        let value = usesFahrenheit(locale) ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    /// "H:29°  L:19°".
    static func range(high: Double, low: Double, locale: Locale = .current) -> String {
        "H:\(temperature(high, locale: locale))  L:\(temperature(low, locale: locale))"
    }

    /// "89%", from 0…100, clamped.
    static func percent(_ value: Double) -> String { "\(Int(min(max(value, 0), 100).rounded()))%" }

    /// "12 km/h", or "7 mph" where the region drives in miles.
    static func wind(_ kilometresPerHour: Double, locale: Locale = .current) -> String {
        let miles = locale.measurementSystem == .us || locale.measurementSystem == .uk
        let speed = Measurement(value: kilometresPerHour, unit: UnitSpeed.kilometersPerHour)
        let converted = miles ? speed.converted(to: .milesPerHour) : speed
        return Measurement(value: converted.value.rounded(), unit: converted.unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided).locale(locale))
    }
}
