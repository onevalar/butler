import XCTest
import WeatherKit
@testable import Butler

@MainActor final class WeatherStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "weather-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
    private func snapshot(_ place: WeatherPlace, _ selection: WeatherLocation, at date: Date = .now,
                          feelsLike: Double = 36, days: [WeatherSnapshot.Day] = []) -> WeatherSnapshot {
        WeatherSnapshot(place: place, selection: selection, fetchedAt: date, observedAt: date, temperature: 28, feelsLike: feelsLike,
                        condition: "Mostly Clear", symbol: "sun.max", windKPH: 12, uvIndex: 5, days: days, alerts: [],
                        legalURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
                        lightMark: URL(string: "https://weatherkit.apple.com/light.svg")!, darkMark: URL(string: "https://weatherkit.apple.com/dark.svg")!)
    }
    func testCacheRefreshAndChangedCityAreConsistent() async throws {
        var calls = 0
        let store = WeatherStore(defaults: defaults()) { place, selection in
            calls += 1; return self.snapshot(place, selection)
        }
        let first = WeatherLocation(city: WeatherPlace(name: "测试城市 A", latitude: 30, longitude: 120))
        try store.setLocation(first)
        await store.refresh(); await store.refresh()
        XCTAssertEqual(calls, 1)
        await store.refresh(force: true)
        XCTAssertEqual(calls, 2)
        let second = WeatherLocation(city: WeatherPlace(name: "测试城市 B", latitude: 40, longitude: 110))
        try store.setLocation(second, expected: first)
        XCTAssertNil(store.snapshot)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.place.name, "测试城市 B")
        XCTAssertThrowsError(try store.setLocation(first, expected: first))
        XCTAssertFalse(store.context.contains("latitude"), "Exact device coordinates must not go to the model")
    }
    func testOldCityResponseCannotReplaceNewSelection() async throws {
        let store = WeatherStore(defaults: defaults()) { place, selection in
            // Deliberately ignore cancellation like an uncooperative network operation.
            try? await Task.sleep(for: .milliseconds(50))
            return self.snapshot(place, selection)
        }
        try store.setLocation(.init(city: .init(name: "旧城市", latitude: 30, longitude: 120)))
        let old = Task { await store.refresh() }
        await Task.yield()
        try store.setLocation(.init(city: .init(name: "新城市", latitude: 40, longitude: 110)))
        await old.value
        XCTAssertNil(store.snapshot)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.place.name, "新城市")
    }
    func testStaleWeatherNeverProducesAnAutomaticHintAndErrorsDoNotFabricateFacts() async throws {
        let city = WeatherPlace(name: "测试城市", latitude: 30, longitude: 120)
        let selected = WeatherLocation(city: city)
        let old = snapshot(city, selected, at: Date.now.addingTimeInterval(-3600))
        XCTAssertFalse(old.isFresh()); XCTAssertNil(old.hint())
        XCTAssertNotNil(snapshot(city, selected).hint())
        let store = WeatherStore(defaults: defaults()) { _, _ in throw URLError(.notConnectedToInternet) }
        try store.setLocation(selected)
        await store.refresh()
        XCTAssertNil(store.snapshot); XCTAssertNotNil(store.error); XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(store.context.contains("\"available\":false"))
    }

    func testBriefReceivesFreshObservationsWithoutRuleWrittenAdvice() throws {
        let now = Date.now
        let city = WeatherPlace(name: "测试城市", latitude: 30, longitude: 120)
        let selected = WeatherLocation(city: city)
        let day = WeatherSnapshot.Day(date: now, symbol: "sun.max", condition: "晴", low: 16, high: 29, rainChance: 0.1)
        let mild = snapshot(city, selected, at: now, feelsLike: 28, days: [day])
        XCTAssertNil(mild.hint(at: now), "A normal 13-degree daily range is not a reason to nag about an extra coat")
        XCTAssertEqual(mild.briefSignature(at: now), "")
        func request(_ weather: WeatherSnapshot) throws -> [String: Any] {
            let raw = BriefModelReply.request(candidates: [], greeting: "中午好", now: now, weather: weather)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        }
        let weather = try XCTUnwrap(try request(mild)["weather"] as? [String: Any])
        XCTAssertNotNil(weather["days"], "The model, not temperature thresholds, decides relevance")
        XCTAssertNil(weather["hint"], "No rule-written recommendation is spliced into the brief")
        let hot = snapshot(city, selected, at: now, feelsLike: 38)
        XCTAssertNotNil(try request(hot)["weather"], "Significant conditions are optional context for the model")
        let stale = snapshot(city, selected, at: now.addingTimeInterval(-3600), feelsLike: 38)
        XCTAssertNil(try request(stale)["weather"])
    }

    func testDestinationReadKeepsHomeSelectionSnapshotAndSearchResults() async throws {
        let home = WeatherPlace(name: "上海", latitude: 31, longitude: 121)
        let destination = WeatherPlace(name: "浙江杭州", latitude: 30, longitude: 120)
        var searches = 0, loads = 0
        let store = WeatherStore(defaults: defaults(), placeSearch: { query in
            searches += 1
            return query == "浙江杭州" ? [destination] : [home]
        }, loader: { place, selection in
            loads += 1
            return self.snapshot(place, selection)
        })
        try store.setLocation(.init(city: home))
        await store.refresh()
        _ = try await store.search("上海")
        let original = store.snapshot
        let result = try await store.destinationForecast("浙江杭州")
        let cached = try await store.destinationForecast(" 浙江杭州 ")
        XCTAssertEqual(result.place, destination)
        XCTAssertEqual(cached, result)
        XCTAssertEqual(searches, 2)
        XCTAssertEqual(loads, 2, "One home load and one destination load; no duplicate destination request")
        XCTAssertEqual(store.selection.city, home)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(store.searchResults, [home], "Background reads cannot overwrite the user's city picker")
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.error)
    }

    func testAmbiguousMissingOrStaleDestinationIsUnknownRatherThanHomeWeather() async throws {
        let a = WeatherPlace(name: "同名城市 A", latitude: 30, longitude: 120)
        let b = WeatherPlace(name: "同名城市 B", latitude: 40, longitude: 110)
        var loads = 0
        let store = WeatherStore(defaults: defaults(), placeSearch: { query in
            query == "重名城市" ? [a, b] : query == "不存在" ? [] : [a]
        }, loader: { place, selection in
            loads += 1
            return self.snapshot(place, selection, at: .now.addingTimeInterval(-1801))
        })
        for query in ["重名城市", "不存在", "唯一城市"] {
            do {
                _ = try await store.destinationForecast(query)
                XCTFail("Must not return guessed or stale weather for \(query)")
            } catch { XCTAssertTrue(error is ButlerTools.ToolError) }
        }
        XCTAssertEqual(loads, 1, "Ambiguous and missing places must never reach the forecast loader")
        XCTAssertNil(store.selection.city)
        XCTAssertNil(store.snapshot)
    }

    func testWeatherLabelsLocalizeExistingEnglishCacheAsWellAsNewData() {
        let city = WeatherPlace(name: "测试城市", latitude: 30, longitude: 120)
        XCTAssertEqual(snapshot(city, .init(city: city)).shortLabel, "28° 晴间多云")
        XCTAssertEqual(WeatherCondition.chineseLabel(for: "小雨"), "小雨")
        for condition in WeatherCondition.allCases {
            XCTAssertEqual(WeatherCondition.chineseLabel(for: condition.description), condition.chineseLabel)
            XCTAssertNotEqual(condition.chineseLabel, condition.description)
        }
    }
}
