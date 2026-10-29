import Foundation
import Testing

@testable import VoxOS

/// Weather parsing and the day summary both feed text straight to the model, so the risks are a
/// wrong reading of the API and an uncapped dump of a day's history. Pure functions, no network.
@Suite
@MainActor
struct AgentWeatherDaySummaryTests {

    private let sample: [String: Any] = [
        "current": [
            "temperature_2m": 21.4, "apparent_temperature": 20.1, "weather_code": 61, "wind_speed_10m": 12.0,
            "relative_humidity_2m": 78.0,
        ],
        "daily": [
            "temperature_2m_max": [24.0, 26.5], "temperature_2m_min": [17.0, 18.2],
            "precipitation_probability_max": [60.0, 10.0], "weather_code": [61, 2],
        ],
    ]

    @Test func readsCurrentConditionsAndTwoDayOutlook() throws {
        let out = try #require(AgentWeather.summarize(sample))
        #expect(out["temperature_c"] as? Double == 21.4)
        #expect(out["conditions"] as? String == "light rain")
        #expect(out["feels_like_c"] as? Double == 20.1)
        let days = try #require(out["outlook"] as? [[String: Any]])
        #expect(days.count == 2)
        #expect(days[0]["day"] as? String == "today")
        #expect(days[0]["rain_chance_pct"] as? Double == 60.0)
        #expect(days[1]["high_c"] as? Double == 26.5)
        #expect(days[1]["conditions"] as? String == "partly cloudy")
    }

    @Test func unknownShapesAreRejectedNotGuessed() {
        #expect(AgentWeather.summarize([:]) == nil)
        #expect(AgentWeather.summarize(["current": ["weather_code": 1]]) == nil, "no temperature, no answer")
    }

    @Test func weatherCodesHaveWordsAndUnknownOnesSayTheCode() {
        #expect(AgentWeather.describe(code: 0) == "clear sky")
        #expect(AgentWeather.describe(code: 95) == "thunderstorm")
        #expect(AgentWeather.describe(code: 42) == "weather code 42")
    }

    @Test func requestAsksForTheLocalTimezone() throws {
        let url = try #require(AgentWeather.url(latitude: 12.9716, longitude: 77.5946))
        let query = url.query ?? ""
        #expect(query.contains("latitude=12.9716") && query.contains("longitude=77.5946"))
        #expect(query.contains("timezone=auto") && query.contains("forecast_days=5"))
    }

    // MARK: Day summary

    private func entry(_ hour: Int, _ text: String, prompt: String? = nil) -> AgentDaySummary.Entry {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        return .init(time: date, text: text, promptName: prompt)
    }

    @Test func anEmptyDaySaysSo() {
        let out = AgentDaySummary.compose([])
        #expect(out["count"] as? Int == 0)
        #expect((out["entries"] as? [String])?.isEmpty == true)
        #expect((out["hint"] as? String)?.contains("Nothing") == true)
    }

    @Test func entriesAreOrderedByTimeAndLabelled() throws {
        let out = AgentDaySummary.compose([entry(14, "afternoon note"), entry(9, "morning plan", prompt: "Agent")])
        let lines = try #require(out["entries"] as? [String])
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("09:00 [Agent]: morning plan"))
        #expect(lines[1].hasPrefix("14:00: afternoon note"))
        #expect(out["truncated"] as? Bool == false)
    }

    @Test func longEntriesAndLongDaysAreCapped() throws {
        let long = String(repeating: "x", count: 1_000)
        let many = (0..<80).map { _ in entry(10, long) }
        let out = AgentDaySummary.compose(many)
        let lines = try #require(out["entries"] as? [String])
        #expect(lines.allSatisfy { $0.count <= AgentDaySummary.maxCharsPerEntry + 12 })
        #expect(lines.count < 80)
        #expect(out["truncated"] as? Bool == true)
        #expect(out["count"] as? Int == 80, "the count is still the real number")
    }

    @Test func blankDictationsAreSkipped() {
        let out = AgentDaySummary.compose([entry(9, "   "), entry(10, "real")])
        #expect((out["entries"] as? [String])?.count == 1)
    }

    // MARK: Reveal + fallback picker

    @Test func revealRefusesOutsideTheHomeFolderAndMissingFiles() {
        #expect(AgentFiles.reveal(path: "")["error"] != nil)
        #expect(AgentFiles.reveal(path: "/etc/passwd")["error"] != nil, "system files are never revealed")
        #expect(AgentFiles.reveal(path: "~/definitely-missing-\(UUID().uuidString)")["error"] != nil)
    }

    @Test func togglingAProviderAppendsInOrderAndRemovesCleanly() {
        var list: [String] = []
        list = AIProviderFallback.toggled(list, "Groq")
        list = AIProviderFallback.toggled(list, "OpenAI")
        #expect(list == ["Groq", "OpenAI"], "order of switching on is the order of trying")
        list = AIProviderFallback.toggled(list, "Groq")
        #expect(list == ["OpenAI"])
    }
}
