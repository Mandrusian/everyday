import Foundation

/// Open-Meteo: free, keyless, no account. Only the city name and its coordinates leave the Mac.
public final class WeatherService: @unchecked Sendable {
    private let prefs: Prefs
    private let db: Database
    public init(db: Database, prefs: Prefs = .shared) { self.db = db; self.prefs = prefs }

    public var city: String {
        get { prefs.string(Prefs.Key.city, default: "Sydney") }
        set { prefs.set(newValue, Prefs.Key.city) }
    }

    static func describe(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81: return "Showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unsettled"
        }
    }

    public func cached() -> WeatherNow? { try? db.get("weather", id: "now") }

    public func fetch() async throws -> WeatherNow {
        let name = city.trimmingCharacters(in: .whitespaces)
        var g = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        g.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "1"), .init(name: "language", value: "en")]
        let (gd, _) = try await URLSession.shared.data(from: g.url!)
        guard let go = try JSONSerialization.jsonObject(with: gd) as? [String: Any], let r = (go["results"] as? [[String: Any]])?.first,
              let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else {
            throw NSError(domain: "weather", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find a place called “\(name)”."])
        }
        var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        f.queryItems = [.init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
                        .init(name: "current", value: "temperature_2m,weather_code"), .init(name: "hourly", value: "temperature_2m"),
                        .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"), .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "2")]
        let (fd, _) = try await URLSession.shared.data(from: f.url!)
        guard let o = try JSONSerialization.jsonObject(with: fd) as? [String: Any], let cur = o["current"] as? [String: Any],
              let temp = cur["temperature_2m"] as? Double, let code = cur["weather_code"] as? Int,
              let daily = o["daily"] as? [String: Any], let hi = (daily["temperature_2m_max"] as? [Double])?.first, let lo = (daily["temperature_2m_min"] as? [Double])?.first,
              let hourly = o["hourly"] as? [String: Any], let times = hourly["time"] as? [String], let temps = hourly["temperature_2m"] as? [Double] else {
            throw NSError(domain: "weather", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected weather response."])
        }
        let tz = TimeZone(identifier: o["timezone"] as? String ?? "") ?? .current
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = tz; df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let now = Date()
        var points: [WeatherNow.HourPoint] = []
        for (i, t) in times.enumerated() where i < temps.count {
            if let d = df.date(from: t), d >= now.addingTimeInterval(-1800), points.count < 12 { points.append(.init(date: d, temp: temps[i])) }
        }
        let w = WeatherNow(city: (r["name"] as? String) ?? name, temperature: temp, high: hi, low: lo, condition: Self.describe(code: code), hourly: points)
        try? db.put("weather", id: "now", w)
        return w
    }
}
