import Foundation

/// Current conditions and a two-day outlook from Open-Meteo: no key, no account, one request.
/// Parsing is pure so it can be tested without the network.
enum AgentWeather {
    private static let conditions: [Int: String] = [
        0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "rime fog",
        51: "light drizzle", 53: "drizzle", 55: "dense drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
        61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
        71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains", 80: "rain showers", 81: "rain showers",
        82: "violent rain showers", 85: "snow showers", 86: "heavy snow showers", 95: "thunderstorm",
        96: "thunderstorm with hail", 99: "thunderstorm with hail",
    ]

    static func describe(code: Int) -> String { conditions[code] ?? "weather code \(code)" }

    /// JSON numbers come back as Int or Double depending on the source; a code is an Int either way.
    static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(
                name: "current",
                value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m,is_day"),
            .init(
                name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"
            ),
            .init(name: "minutely_15", value: "precipitation"),
            .init(name: "forecast_minutely_15", value: "8"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
        ]
        return components?.url
    }

    /// The few fields a spoken answer needs, or nil when the response is not Open-Meteo's shape.
    static func summarize(_ json: [String: Any]) -> [String: Any]? {
        guard let current = json["current"] as? [String: Any], let temperature = current["temperature_2m"] as? Double
        else { return nil }
        var out: [String: Any] = [
            "temperature_c": temperature,
            "conditions": describe(code: int(current["weather_code"]) ?? -1),
        ]
        if let feels = current["apparent_temperature"] as? Double { out["feels_like_c"] = feels }
        if let wind = current["wind_speed_10m"] as? Double { out["wind_kmh"] = wind }
        if let humidity = current["relative_humidity_2m"] as? Double { out["humidity_pct"] = humidity }
        if let day = int(current["is_day"]) { out["is_day"] = day == 1 }
        // Minutes until the first quarter hour with rain in the next two hours: 0 is now.
        if let quarters = (json["minutely_15"] as? [String: Any])?["precipitation"] as? [Any] {
            let amounts = quarters.map { number(["v": $0], "v") ?? 0 }
            if let first = amounts.firstIndex(where: { $0 >= 0.1 }) { out["rain_in_minutes"] = first * 15 }
        }

        if let daily = json["daily"] as? [String: Any],
            let highs = daily["temperature_2m_max"] as? [Double], let lows = daily["temperature_2m_min"] as? [Double]
        {
            let rain = daily["precipitation_probability_max"] as? [Double] ?? []
            let codes = (daily["weather_code"] as? [Any])?.compactMap(int) ?? []
            var days: [[String: Any]] = []
            for (index, label) in ["today", "tomorrow"].enumerated() where index < highs.count && index < lows.count {
                var day: [String: Any] = ["day": label, "high_c": highs[index], "low_c": lows[index]]
                if index < rain.count { day["rain_chance_pct"] = rain[index] }
                if index < codes.count { day["conditions"] = describe(code: codes[index]) }
                days.append(day)
            }
            out["outlook"] = days
        }
        return out
    }

    private static func number(_ dict: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = dict[key] as? Double { return value }
            if let text = dict[key] as? String, let value = Double(text) { return value }
        }
        return nil
    }

    static func current() async -> [String: Any] {
        let location = await AgentLocation.current()
        guard let latitude = number(location, "latitude", "lat"),
            let longitude = number(location, "longitude", "lon", "lng")
        else {
            return ["error": (location["error"] as? String) ?? "Your location is not available."]
        }
        guard let url = url(latitude: latitude, longitude: longitude) else {
            return ["error": "could not build the request"]
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                var summary = summarize(json)
            else { return ["error": "unexpected weather response"] }
            for key in ["place", "city", "locality", "name"] {
                if let place = location[key] as? String, !place.isEmpty {
                    summary["place"] = place
                    break
                }
            }
            return summary
        } catch {
            return ["error": "weather lookup failed: \(error.localizedDescription)"]
        }
    }
}
