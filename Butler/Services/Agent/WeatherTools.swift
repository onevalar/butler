import Foundation

extension ButlerTools {
    static var weatherTools: String {
        let tools = [
            functionSchema("get_weather", "读取已选位置的真实天气和未来7天预报，自动使用30分钟缓存；refresh=true主动更新。注意fresh、观测/更新时间和error，陈旧或不可用时不能当作今天实况。不请求系统权限。", ["refresh": ["type": "boolean"]]),
            functionSchema("get_destination_weather", "只读查询已知出行目的地的天气、未来48小时和7天预报；query须为明确的城市/地区，补足省份或国家。不会更改首页天气位置，也不请求定位权限。available=false表示未知，不能用本地天气替代；只能在预报覆盖时段内推断。", ["query": ["type": "string"]]),
            functionSchema("search_weather_places", "搜索天气城市或地区，返回候选place_id。城市有重名时请用户选择，不能猜坐标。", ["query": ["type": "string"]]),
            functionSchema("propose_weather_location", "修改天气位置，确认后生效。place_id用search_weather_places返回值；null切回手机定位（系统权限仍由用户授权）。", ["place_id": ["type": ["string", "null"]]])
        ]
        return ToolSchema.json(tools, sortedKeys: true)
    }
    func executeWeatherTool(_ name: String, data: Data) async throws -> String? {
        switch name {
        case "get_weather":
            struct Args: Decodable { let refresh: Bool }
            let args = try JSONDecoder().decode(Args.self, from: data)
            await weather.refresh(force: args.refresh)
            return weather.context
        case "get_destination_weather":
            struct Args: Decodable { let query: String }
            let args = try JSONDecoder().decode(Args.self, from: data)
            do {
                let snapshot = try await weather.destinationForecast(args.query)
                guard var facts = BriefModelReply.weatherContext(snapshot, now: .now) else {
                    return try encode(["available": false, "reason": "目的地天气已过期"] as [String: Any])
                }
                facts["available"] = true
                facts["source"] = "Apple Weather"
                facts["valid_until"] = min(snapshot.fetchedAt.addingTimeInterval(1800), snapshot.observedAt.addingTimeInterval(7200)).ISO8601Format()
                return try encode(facts)
            } catch is CancellationError { throw CancellationError() }
            catch {
                return try encode(["available": false, "reason": (error as? ToolError)?.message ?? "目的地天气暂时无法读取"] as [String: Any])
            }
        case "search_weather_places":
            struct Args: Decodable { let query: String }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let places = try await weather.search(args.query)
            return try encode(["places": places.map { ["place_id": $0.id.uuidString, "name": $0.name] }])
        case "propose_weather_location":
            struct Args: Decodable { let place_id: UUID? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            var selection = WeatherLocation()
            if let id = args.place_id {
                guard let city = weather.searchResults.first(where: { $0.id == id }) else { throw ToolError("请先搜索并选择城市") }
                selection.city = city
            }
            add(.weatherLocation(selection, before: weather.selection), title: "天气位置：\(selection.label)", detail: "首页天气和对话建议共同使用，定位仍需系统授权")
            return pendingContext
        default: return nil
        }
    }
}
