import CoreLocation
import MapKit
import Foundation
import Observation
import WeatherKit

struct WeatherPlace: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    var timeZoneIdentifier: String?
}
struct WeatherLocation: Codable, Equatable, Sendable {
    /// nil follows the phone, without background location access.
    var city: WeatherPlace?
    var label: String { city?.name ?? "手机定位" }
}
struct WeatherSnapshot: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Identifiable, Sendable {
        let date: Date; let symbol: String; let condition: String
        let low: Double; let high: Double; let rainChance: Double
        var id: Date { date }
    }
    struct Alert: Codable, Equatable, Identifiable, Sendable {
        let text: String; let url: URL
        var id: URL { url }
    }
    let place: WeatherPlace
    let selection: WeatherLocation
    let fetchedAt: Date
    let observedAt: Date
    let temperature: Double
    let feelsLike: Double
    let condition: String
    let symbol: String
    let windKPH: Double
    let uvIndex: Int
    let days: [Day]
    let alerts: [Alert]
    let legalURL: URL
    let lightMark: URL
    let darkMark: URL
    func isFresh(at now: Date = .now) -> Bool { (0..<1800).contains(now.timeIntervalSince(fetchedAt)) && now.timeIntervalSince(observedAt) < 7200 }
    /// Ordinary weather changes must not regenerate the household brief.
    func briefSignature(at now: Date) -> String { hint(at: now).map { place.name + "|" + $0 } ?? "" }
    func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = place.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date)
    }
    var conditionLabel: String { WeatherCondition.chineseLabel(for: condition) }
    var shortLabel: String { "\(Int(temperature.rounded()))° \(conditionLabel)" }
    /// Optional context for the brief writer, never a mandatory extra line on the home card.
    func hint(at now: Date = .now) -> String? {
        guard isFresh(at: now) else { return nil }
        if let alert = alerts.first { return alert.text }
        if feelsLike >= 35 { return "体感较热，出门留意补水和防晒。" }
        if feelsLike <= 0 { return "室外体感在零度以下，出门留意保暖。" }
        if windKPH >= 40 { return "当前风较大，出门留意防风。" }
        if let day = days.first, day.rainChance >= 0.6 { return "今天有降水可能，出门记得带伞。" }
        return nil
    }
}

@MainActor @Observable
final class WeatherStore: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherStore()
    private(set) var selection: WeatherLocation
    private(set) var snapshot: WeatherSnapshot?
    private(set) var isRefreshing = false
    private(set) var error: String?
    private(set) var searchResults: [WeatherPlace] = []
    typealias Loader = @MainActor (WeatherPlace, WeatherLocation) async throws -> WeatherSnapshot
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var locationWaiter: CheckedContinuation<CLLocation, Error>?
    @ObservationIgnored private var locationTimeout: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var failedAt: Date?

    init(defaults: UserDefaults = .standard, loader: Loader? = nil) {
        self.loader = loader ?? Self.fetch
        self.defaults = defaults
        selection = defaults.data(forKey: "weatherLocation").flatMap { try? JSONDecoder().decode(WeatherLocation.self, from: $0) } ?? WeatherLocation()
        snapshot = defaults.data(forKey: "weatherSnapshot").flatMap { try? JSONDecoder().decode(WeatherSnapshot.self, from: $0) }
        super.init()
        if snapshot?.selection != selection { snapshot = nil }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }
    nonisolated deinit {}

    func setLocation(_ value: WeatherLocation, expected: WeatherLocation? = nil) throws {
        if let expected, selection != expected { throw ButlerTools.ToolError("天气位置已经变化，请重新读取") }
        if let city = value.city {
            guard (-90...90).contains(city.latitude), (-180...180).contains(city.longitude), !city.name.isEmpty else { throw ButlerTools.ToolError("天气位置无效") }
        }
        let data = try JSONEncoder().encode(value)
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; isRefreshing = false
        finishLocation(.failure(CancellationError()))
        selection = value; snapshot = nil; failedAt = nil; error = nil
        defaults.set(data, forKey: "weatherLocation"); defaults.removeObject(forKey: "weatherSnapshot")
    }
    func search(_ query: String) async throws -> [WeatherPlace] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...80).contains(query.count) else { throw ButlerTools.ToolError("请输入城市或地区名称") }
        guard let request = MKGeocodingRequest(addressString: query) else { throw ButlerTools.ToolError("无法查找这个城市") }
        request.preferredLocale = Locale(identifier: "zh_CN")
        let places = try await request.mapItems
        searchResults = places.prefix(8).compactMap { place in
            let coordinate = place.location.coordinate
            return WeatherPlace(name: place.addressRepresentations?.cityWithContext(.full) ?? place.name ?? query, latitude: coordinate.latitude, longitude: coordinate.longitude, timeZoneIdentifier: place.timeZone?.identifier)
        }
        return searchResults
    }
    /// Passive reads never trigger the location permission prompt. A direct UI tap may request it.
    func refresh(force: Bool = false, requestPermission: Bool = false) async {
        if let task = refreshTask { await task.value; return }
        if !force, let snapshot, snapshot.selection == selection, snapshot.isFresh() { return }
        if !force, let failedAt, Date.now.timeIntervalSince(failedAt) < 60 { return }
        let token = generation
        isRefreshing = true; error = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == token { isRefreshing = false; refreshTask = nil } }
            do {
                let place: WeatherPlace
                if let manual = selection.city { place = manual }
                else {
                    let location = try await deviceLocation(requestPermission: requestPermission)
                    try Task.checkCancellation()
                    let reverse = MKReverseGeocodingRequest(location: location)
                    reverse?.preferredLocale = Locale(identifier: "zh_CN")
                    let names = try? await reverse?.mapItems
                    // Weather needs neighborhood precision, not a home address.
                    place = WeatherPlace(name: names?.first?.addressRepresentations?.cityWithContext ?? "当前位置",
                                         latitude: (location.coordinate.latitude * 100).rounded() / 100,
                                         longitude: (location.coordinate.longitude * 100).rounded() / 100, timeZoneIdentifier: names?.first?.timeZone?.identifier)
                }
                let result = try await loader(place, selection)
                try Task.checkCancellation()
                guard generation == token else { return }
                snapshot = result; failedAt = nil
                defaults.set(try JSONEncoder().encode(result), forKey: "weatherSnapshot")
            } catch is CancellationError {} catch {
                guard generation == token else { return }
                failedAt = .now
                self.error = (error as? ButlerTools.ToolError)?.message ?? "天气暂时无法更新，请稍后重试。"
                ChatDiagnostics.log("weather refresh failed: \(String(describing: type(of: error)))")
            }
        }
        refreshTask = task
        await task.value
    }
    private static func fetch(_ place: WeatherPlace, _ selection: WeatherLocation) async throws -> WeatherSnapshot {
                let service = WeatherService.shared
                async let weather = service.weather(for: CLLocation(latitude: place.latitude, longitude: place.longitude))
                async let attribution = service.attribution
                let (value, credit) = try await (weather, attribution)
                try Task.checkCancellation()
                let current = value.currentWeather
                return WeatherSnapshot(place: place, selection: selection, fetchedAt: .now, observedAt: current.date,
                    temperature: current.temperature.converted(to: .celsius).value, feelsLike: current.apparentTemperature.converted(to: .celsius).value,
                    condition: current.condition.chineseLabel, symbol: current.symbolName, windKPH: current.wind.speed.converted(to: .kilometersPerHour).value,
                    uvIndex: current.uvIndex.value, days: value.dailyForecast.forecast.prefix(7).map {
                        .init(date: $0.date, symbol: $0.symbolName, condition: $0.condition.chineseLabel,
                              low: $0.lowTemperature.converted(to: .celsius).value, high: $0.highTemperature.converted(to: .celsius).value, rainChance: $0.precipitationChance)
                    }, alerts: (value.weatherAlerts ?? []).map { .init(text: $0.summary, url: $0.detailsURL) },
                    legalURL: credit.legalPageURL, lightMark: credit.combinedMarkLightURL, darkMark: credit.combinedMarkDarkURL)
    }

    private func deviceLocation(requestPermission: Bool) async throws -> CLLocation {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { throw ButlerTools.ToolError("定位未授权，可以手动选择城市或在系统设置开启定位。") }
        if status == .notDetermined, !requestPermission { throw ButlerTools.ToolError("点开天气可启用手机定位，也可以手动选择城市。") }
        return try await withCheckedThrowingContinuation { continuation in
            locationWaiter = continuation
            locationTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finishLocation(.failure(ButlerTools.ToolError("暂时无法定位，可以手动选择城市。")))
            }
            if status == .notDetermined { manager.requestWhenInUseAuthorization() }
            else { manager.requestLocation() }
        }
    }
    private func finishLocation(_ result: Result<CLLocation, Error>) {
        locationTimeout?.cancel(); locationTimeout = nil
        let waiter = locationWaiter; locationWaiter = nil
        waiter?.resume(with: result)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locationWaiter != nil else { return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            finishLocation(.failure(ButlerTools.ToolError("定位未授权，可以手动选择城市。")))
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) < 300 else {
            finishLocation(.failure(ButlerTools.ToolError("没有取得有效位置，可以手动选择城市。"))); return
        }
        finishLocation(.success(location))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation(.failure(ButlerTools.ToolError("暂时无法定位，可以手动选择城市。")))
    }
    var context: String {
        var result: [String: Any] = ["source": "Apple Weather", "location_mode": selection.city == nil ? "device" : "manual", "location": selection.label]
        if let snapshot {
            // Exact coordinates stay on the phone. The model gets the selected city and weather facts.
            result["place"] = snapshot.place.name
            result["time_zone"] = snapshot.place.timeZoneIdentifier ?? TimeZone.current.identifier
            result["fetched_at"] = snapshot.fetchedAt.ISO8601Format(); result["observed_at"] = snapshot.observedAt.ISO8601Format()
            result["fresh"] = snapshot.isFresh(); result["temperature_c"] = snapshot.temperature; result["feels_like_c"] = snapshot.feelsLike
            result["condition"] = snapshot.conditionLabel; result["wind_kph"] = snapshot.windKPH; result["uv_index"] = snapshot.uvIndex
            result["days"] = snapshot.days.map { ["date": snapshot.dayLabel($0.date), "low_c": $0.low, "high_c": $0.high, "rain_chance": $0.rainChance, "condition": WeatherCondition.chineseLabel(for: $0.condition)] as [String: Any] }
            result["alerts"] = snapshot.alerts.map { ["text": $0.text, "url": $0.url.absoluteString] }
        } else { result["available"] = false }
        if let error { result["error"] = error }
        return (try? JSONSerialization.data(withJSONObject: result)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension WeatherCondition {
    /// WeatherKit's description is English. Also handles snapshots cached by older app versions.
    static func chineseLabel(for stored: String) -> String {
        allCases.first { $0.description == stored || $0.rawValue == stored }?.chineseLabel ?? stored
    }
    var chineseLabel: String {
        switch self {
        case .blizzard: "暴风雪"
        case .blowingDust: "扬沙"
        case .blowingSnow: "风吹雪"
        case .breezy: "微风"
        case .clear: "晴"
        case .cloudy: "阴"
        case .drizzle: "毛毛雨"
        case .flurries: "零星小雪"
        case .foggy: "雾"
        case .freezingDrizzle: "冻毛毛雨"
        case .freezingRain: "冻雨"
        case .frigid: "严寒"
        case .hail: "冰雹"
        case .haze: "霾"
        case .heavyRain: "大雨"
        case .heavySnow: "大雪"
        case .hot: "炎热"
        case .hurricane: "飓风"
        case .isolatedThunderstorms: "局部雷阵雨"
        case .mostlyClear: "晴间多云"
        case .mostlyCloudy: "大部多云"
        case .partlyCloudy: "局部多云"
        case .rain: "雨"
        case .scatteredThunderstorms: "分散性雷阵雨"
        case .sleet: "冰粒"
        case .smoky: "烟尘"
        case .snow: "雪"
        case .strongStorms: "强雷暴"
        case .sunFlurries: "晴间小雪"
        case .sunShowers: "太阳雨"
        case .thunderstorms: "雷阵雨"
        case .tropicalStorm: "热带风暴"
        case .windy: "大风"
        case .wintryMix: "雨雪混合"
        @unknown default: "天气"
        }
    }
}
