import Foundation
import Testing

@testable import VoxOS

/// The Weather page's forecast and arithmetic: the parts that can be wrong rather than merely look
/// wrong.
@Suite
@MainActor
struct NotchWeatherPageTests {

    // MARK: Weather

    private let summary: [String: Any] = [
        "temperature_c": 19.4, "feels_like_c": 17.2, "humidity_pct": 89.0, "wind_kmh": 12.3, "is_day": false,
        "conditions": "partly cloudy", "place": "Somewhere",
        "outlook": [["day": "today", "high_c": 29.0, "low_c": 19.0, "rain_chance_pct": 0.0]],
        "forecast": [
            ["date": "2026-10-29", "high_c": 29.0, "low_c": 19.0, "rain_chance_pct": 0.0, "conditions": "clear sky"],
            ["date": "2026-10-30", "high_c": 28.6, "low_c": 18.0, "conditions": "partly cloudy"],
            ["date": "not a date", "high_c": 30.0, "low_c": 18.0],
            [
                "date": "2026-11-01", "high_c": 29.0, "low_c": 20.0, "rain_chance_pct": 41.0,
                "conditions": "rain showers",
            ],
        ],
    ]

    @Test func theSummaryFillsTheWeatherPage() throws {
        let now = Date()
        let weather = try #require(NotchToday.weather(from: summary, now: now))
        #expect(weather.temperatureC == 19.4)
        #expect(weather.feelsLikeC == 17.2)
        #expect(weather.humidity == 89)
        #expect(weather.windKPH == 12.3)
        #expect(weather.rainChance == 0)
        #expect(weather.readAt == now)
        #expect(weather.symbol == "cloud.moon.fill", "night: a moon where the day has a sun")
        #expect(weather.days.count == 3, "a day that cannot be read is left out")
        let first = try #require(weather.days.first)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: first.date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 29 && parts.hour == 0)
        #expect(first.symbol == "sun.max.fill")
        #expect(weather.days[1].rainChance == nil)
        #expect(weather.days[2].rainChance == 41)
    }

    @Test func theOpenMeteoSummaryCarriesFiveDatedDays() throws {
        let json: [String: Any] = [
            "current": ["temperature_2m": 21.0, "weather_code": 1],
            "daily": [
                "time": ["2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"],
                "temperature_2m_max": [29.0, 28.0, 30.0, 29.0, 27.0],
                "temperature_2m_min": [19.0, 18.0, 18.0, 20.0, 19.0],
                "precipitation_probability_max": [0.0, 5.0, 2.0, 41.0, 45.0], "weather_code": [1, 2, 0, 80, 61],
            ],
        ]
        let out = try #require(AgentWeather.summarize(json))
        let forecast = try #require(out["forecast"] as? [[String: Any]])
        #expect(forecast.count == 5)
        #expect(forecast[3]["date"] as? String == "2026-11-01")
        #expect(forecast[3]["rain_chance_pct"] as? Double == 41)
        #expect(forecast[3]["conditions"] as? String == "rain showers")
        #expect((out["outlook"] as? [[String: Any]])?.count == 2, "a spoken answer still gets two days")
    }

    @Test func aDaysRangeSitsOnTheWeeksTrack() {
        #expect(NotchWeatherRange.bounds(of: []) == nil)
        let bounds = 18.0...30.0
        let day = NotchWeatherRange.segment(low: 21, high: 27, in: bounds)
        #expect(day.start == 0.25)
        #expect(day.length == 0.5)
        let flat = NotchWeatherRange.segment(low: 20, high: 20, in: bounds)
        #expect(flat.length > 0, "a day whose low is its high is still drawn")
        #expect(NotchWeatherRange.segment(low: 20, high: 20, in: 20...20) == (0, 1), "no spread: every day full")
        let past = NotchWeatherRange.segment(low: 10, high: 40, in: bounds)
        #expect(past.start == 0 && past.length == 1, "clamped to the track")
        #expect(NotchWeatherRange.position(24, within: day, in: bounds) == 0.5)
        #expect(NotchWeatherRange.position(31, within: day, in: bounds) == 0.75, "kept on today's segment")
    }

    @Test func theScaleColoursColdBlueAndHotOrange() {
        let cold = NotchWeatherScale.components(atCelsius: -40)
        let hot = NotchWeatherScale.components(atCelsius: 50)
        #expect(cold.blue > cold.red)
        #expect(hot.red > hot.blue)
        let bar = NotchWeatherScale.gradient(from: 15, to: 32)
        #expect(bar.first?.location == 0 && bar.last?.location == 1)
        #expect(bar.count == 5, "it bends at the 17°, 23° and 30° stops in between")
        #expect(zip(bar, bar.dropFirst()).allSatisfy { $0.location < $1.location })
        #expect(NotchWeatherScale.gradient(from: 20, to: 20).count == 2)
    }

    @Test func theHeaderNamesTheCity() {
        #expect(NotchWeatherPage.city("Bengaluru, Karnataka, India") == "Bengaluru")
        #expect(NotchWeatherPage.city("Paris") == "Paris")
        #expect(NotchWeatherPage.city(" , France") == nil)
    }

    @Test func numbersAreWrittenForTheRegion() {
        let india = Locale(identifier: "en_IN")
        let us = Locale(identifier: "en_US")
        #expect(NotchWeatherFormat.temperature(19.5, locale: india) == "20°")
        #expect(NotchWeatherFormat.temperature(-0.6, locale: india) == "-1°")
        #expect(NotchWeatherFormat.temperature(20, locale: us) == "68°")
        #expect(NotchWeatherFormat.range(high: 29, low: 19, locale: india) == "H:29°  L:19°")
        #expect(NotchWeatherFormat.percent(104) == "100%")
        #expect(NotchWeatherFormat.percent(88.6) == "89%")
        #expect(NotchWeatherFormat.wind(12.3, locale: india).contains("12"))
        #expect(NotchWeatherFormat.wind(16.09, locale: us).contains("10"))
    }
}
