import Foundation

extension ButlerTools {
    static var travelTools: String {
        let string: [String: Any] = ["type": "string"], optional: [String: Any] = ["type": ["string", "null"]]
        let tools = [
            functionSchema("get_travel_capabilities", "查看可选地点/出行能力，不请求定位。到家提醒是进入地点范围，不是按预计到家时间响铃。", [:]),
            functionSchema("propose_travel_access", "确认本次运行的地点对话许可：必要名称、地址、路线摘要给当前模型，查找/路线发给苹果地图。关闭不取消已安排地点提醒，也不能撤回历史。", ["allowed": ["type": "boolean"]]),
            functionSchema("search_travel_places", "按地址/名称查找最多10个候选。不请求定位。near_id=null时用查询中明确的城市范围；附近查询须先取得明确的参考地点编号。同名先询问，不能猜坐标。", ["query": string, "near_id": optional]),
            functionSchema("propose_current_travel_place", "仅在用户明确要使用当前位置时，确认后单次定位并由苹果反查地址，返回候选编号；不自动标记为家，不持续跟踪。到家提醒未设家时先询问地址，除非用户明确说现在在家。", [:]),
            functionSchema("get_saved_places", "按需查询已确认的本机常用地点称呼、名称、地址及编号，不推断家在哪里。", [:]),
            functionSchema("propose_save_place", "确认后保存地点称呼（例如家）。point_id来自查找/本次定位/已有地点；existing_id=null新建，否则明确修改该编号。仍有活动提醒的地点须先取消提醒才能修改。", ["alias": string, "point_id": string, "existing_id": optional]),
            functionSchema("propose_remove_place", "确认后删除已保存地点；有活动或结果未知提醒时拒绝，先取消提醒。", ["place_id": string]),
            functionSchema("get_travel_route", "查询明确起终点的驾车/步行路线预计耗时和到达时刻，不创建提醒，不打开地图。编号来自真实候选/已保存地点；departure=null为现在，否则带时区ISO8601时间（未来30天内）。不支持公交时不能用驾车代替。", ["origin_id": string, "destination_id": string, "mode": ["type": "string", "enum": ["driving", "walking"]], "departure": optional]),
            functionSchema("propose_open_travel_route", "选择最近查询返回的route_id，确认后仅请求苹果地图打开该起终点路线，地图会重新算路，不承诺沿用预计到达时间。", ["route_id": string]),
            functionSchema("propose_place_reminder", "到家/到公司提醒：先确认保存准确地点，再明确提醒内容。radius_m为100–2000米，默认建议200米且在确认卡展示。repeats=false下一次进入提醒一次；只有每次都提醒的明确意图才true。已在范围内意味着离开后再进入；不是立即提醒/定时提醒，不以ETA代替。", ["place_id": string, "text": string, "radius_m": ["type": "number"], "repeats": ["type": "boolean"]]),
            functionSchema("get_place_reminders", "读取并核对地点提醒，缺失/unknown不等于完成或已通知。不会重新安排；取消中可再次确认取消。最多返回最近100条，活动项优先。", [:]),
            functionSchema("propose_cancel_place_reminder", "确认后移除指定地点通知，不完成普通任务/不停止闹钟；修改内容、范围或重复方式时先取消旧项，再明确新建。", ["reminder_id": string])
        ]
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: ",")
    }
    func executeTravelTool(_ name: String, data: Data) async throws -> String? {
        let change: TravelChange, title: String, detail: String
        func summary(_ p: TravelPoint, id: UUID? = nil) -> [String: Any] {
            ["id": (id ?? p.id).uuidString, "name": p.name, "address": p.address, "time_zone": p.timeZone as Any? ?? NSNull()]
        }
        switch name {
        case "get_travel_capabilities":
            return try encode(["conversation_access": travel.allowed, "route_modes": ["driving", "walking"],
                "max_place_reminders": 10, "note": "按需使用，不持续追踪。地点通知由系统监测，只申请使用期间定位与通知；需精确位置。可能延迟、被专注模式影响或失效，不适合紧急安全用途。"] as [String: Any])
        case "propose_travel_access":
            struct Args: Decodable { let allowed: Bool }
            let args = try JSONDecoder().decode(Args.self, from: data)
            change = .access(args.allowed); title = args.allowed ? "允许地点资料用于当前模型对话" : "关闭地点对话访问"
            detail = "按需将地点名称、地址和路线摘要用于当前配置模型及对话历史；坐标保留本机，但查找/路线/反查地址请求发送给苹果地图。本次运行有效，不立即申请定位。关闭不取消已安排的地点提醒，也不能撤回已发资料。"
        case "search_travel_places":
            struct Args: Decodable { let query: String; let near_id: UUID? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let points = try await travel.search(args.query, near: args.near_id)
            return try encode(["candidates": points.map { summary($0) }, "note": "最多10个候选，不是全部结果；同名先选准确地址。"] as [String: Any])
        case "propose_current_travel_place":
            change = .current; title = "获取本次当前位置候选"
            detail = "确认后单次定位，并发给苹果反查地址；地址用于当前模型对话。不会自动当作家，不保存轨迹。未授权时可输入地址代替。"
        case "get_saved_places":
            let places = try travel.places()
            return try encode(places.map { p in summary(p.point, id: p.id).merging(["alias": p.alias, "revision": p.revision]) { _, new in new } })
        case "propose_save_place":
            struct Args: Decodable { let alias: String; let point_id: UUID; let existing_id: UUID? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            change = try travel.saveProposal(alias: args.alias, candidateID: args.point_id, existingID: args.existing_id)
            guard case .save(let alias, let p, let old) = change else { throw TravelFailure("地点提案无效。") }
            title = "\(old == nil ? "保存" : "修改")地点「\(alias)」"
            detail = "\(old.map { "原地点：\($0.alias)，\($0.point.address)\n" } ?? "")新地点：\(p.name)，\(p.address)。请核对是你指的家/地点。坐标仅保存在本机，不创建提醒。"
        case "propose_remove_place":
            struct Args: Decodable { let place_id: UUID }
            let p = try travel.place(JSONDecoder().decode(Args.self, from: data).place_id)
            change = .remove(p); title = "删除地点「\(p.alias)」"; detail = "\(p.point.address)。有活动提醒时先取消，不自动删除历史。"
        case "get_travel_route":
            struct Args: Decodable { let origin_id: UUID; let destination_id: UUID; let mode: TravelMode; let departure: String? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let departure = try args.departure.map(Self.calendarDate) ?? .now
            let (id, route) = try await travel.route(from: args.origin_id, to: args.destination_id, mode: args.mode, departure: departure)
            return try encode(["route_id": id.uuidString, "origin": summary(route.origin), "destination": summary(route.destination),
                "departure": route.departure.ISO8601Format(), "estimated_arrival": route.arrival.ISO8601Format(),
                "meters": route.meters, "seconds": route.seconds, "checked_at": route.checkedAt.ISO8601Format(),
                "note": "苹果地图估算，不保证准时到达。未打开导航、未设置出发提醒或到家提醒。"] as [String: Any])
        case "propose_open_travel_route":
            struct Args: Decodable { let route_id: UUID }
            change = try travel.navigation(JSONDecoder().decode(Args.self, from: data).route_id)
            guard case .navigate(let route) = change else { throw TravelFailure("路线提案无效。") }
            title = "打开苹果地图路线"
            detail = "\(route.origin.name)，\(route.origin.address) → \(route.destination.name)，\(route.destination.address)；\(route.mode == .driving ? "驾车" : "步行")。地图会重新算路，未自动设置提醒。"
        case "propose_place_reminder":
            struct Args: Decodable { let place_id: UUID; let text: String; let radius_m: Double; let repeats: Bool }
            let args = try JSONDecoder().decode(Args.self, from: data), p = try travel.place(args.place_id)
            try PlaceReminder(id: UUID(), place: p, text: args.text, radius: args.radius_m, repeats: args.repeats, state: .attempting).validate()
            change = .remind(place: p, text: args.text, radius: args.radius_m, repeats: args.repeats)
            title = "\(args.repeats ? "每次到达" : "下次到达")「\(p.alias)」附近提醒"
            detail = "\(args.text)\n地址：\(p.point.address)，半径\(Int(args.radius_m))米。已在范围内则离开后再进入。确认后按需申请使用期间定位（需精确位置）和通知，由系统监测；不记录轨迹，不改成定时提醒。可能延迟或受系统设置影响。"
        case "get_place_reminders":
            try await travel.refresh()
            let all = try travel.reminders(), rows = (all.filter(\.reservesPlace) + all.filter { !$0.reservesPlace }.reversed()).prefix(100)
            return try encode(["reminders": rows.map { r in ["id": r.id.uuidString, "place_id": r.place.id.uuidString,
                "place": r.place.alias, "address": r.place.point.address, "text": r.text, "radius_m": r.radius,
                "repeats": r.repeats, "state": r.state.rawValue] as [String: Any] }, "total": all.count,
                "note": "scheduled表示当前请求存在，不保证触发；delivered表示查到通知中心记录，不表示已阅读/完成；unknown缺少证据，不重建。"] as [String: Any])
        case "propose_cancel_place_reminder":
            struct Args: Decodable { let reminder_id: UUID }
            let args = try JSONDecoder().decode(Args.self, from: data)
            guard let r = try travel.reminders().first(where: { $0.id == args.reminder_id }) else { throw TravelFailure("找不到地点提醒。") }
            change = .cancel(r.id); title = "取消到「\(r.place.alias)」附近的提醒"
            detail = "\(r.text)。只取消这个地点通知，不完成任务，也不删除已保存地点。"
        default: return nil
        }
        if !pending.contains(where: { if case .travel(let old) = $0.kind { old == change } else { false } }) {
            add(.travel(change), title: title, detail: detail)
        }
        return #"{"proposed":true,"saved":false,"confirmation_required":true}"#
    }
}
