import Foundation

@MainActor final class TravelStore {
    struct Records: Codable {
        var places: [SavedPlace] = []
        var reminders: [PlaceReminder] = []
        var consumed: Set<UUID> = []
    }
    private let file: URL
    private let device: any TravelDevice
    private var records = Records()
    private var failed = false
    private var busy = false
    private var generation = UUID()
    private var candidates: [TravelPoint] = []
    private var routes: [UUID: TravelRoute] = [:]
    private var transientConsumed: Set<UUID> = []
    private(set) var allowed = false
    init(file: URL, device: any TravelDevice, preparationFailed: Bool = false) {
        self.file = file; self.device = device; failed = preparationFailed
        guard !failed else { return }
        do { records = try JSONDecoder().decode(Records.self, from: Data(contentsOf: file)) }
        catch {
            let e = error as NSError
            failed = e.domain != NSCocoaErrorDomain || e.code != NSFileReadNoSuchFileError
        }
    }
    nonisolated deinit {}
    private func ready(_ token: UUID? = nil) throws {
        guard !failed, allowed, token == nil || token == generation else { throw TravelFailure("请先按需确认地点对话许可；许可已关闭或本地记录不可读时停止访问。") }
        try Task.checkCancellation()
    }
    func places() throws -> [SavedPlace] { try ready(); return records.places }
    func reminders() throws -> [PlaceReminder] { try ready(); return records.reminders }
    func point(_ id: UUID) throws -> TravelPoint {
        try ready()
        guard let p = candidates.first(where: { $0.id == id }) ?? records.places.first(where: { $0.id == id })?.point else {
            throw TravelFailure("请先查找并选择准确地点，不能猜坐标或把天气城市当作家。")
        }
        try p.validate(); return p
    }
    func place(_ id: UUID) throws -> SavedPlace {
        try ready()
        guard let p = records.places.first(where: { $0.id == id }) else { throw TravelFailure("未保存此地点，请先标记家的地址。") }
        return p
    }
    func search(_ query: String, near: UUID?) async throws -> [TravelPoint] {
        try ready(); let token = generation
        guard (1...200).contains(query.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw TravelFailure("请提供具体地址或地点名称。") }
        let result = try await device.search(query, near: try near.map(point))
        try ready(token)
        let page = Array(result.prefix(10))
        candidates = Array((candidates.filter { old in !page.contains(where: { $0.id == old.id }) } + page).suffix(40))
        return page
    }
    func route(from: UUID, to: UUID, mode: TravelMode, departure: Date) async throws -> (UUID, TravelRoute) {
        try ready(); let token = generation
        guard (-300...2_592_000).contains(departure.timeIntervalSinceNow) else { throw TravelFailure("路线出发时间须为现在或未来30天内，时间必须带时区。") }
        let result = try await device.route(from: point(from), to: point(to), mode: mode, departure: departure)
        try ready(token)
        let id = UUID(); routes = [id: result]
        return (id, result)
    }
    func navigation(_ id: UUID) throws -> TravelChange {
        try ready()
        guard let route = routes[id] else { throw TravelFailure("请先查路线再选择导航。") }
        return .navigate(route)
    }
    func saveProposal(alias: String, candidateID: UUID, existingID: UUID?) throws -> TravelChange {
        try ready()
        return .save(alias: alias.trimmingCharacters(in: .whitespacesAndNewlines), point: try point(candidateID), before: try existingID.map(place))
    }
    private func checkPlace(_ before: SavedPlace) throws {
        guard records.places.contains(before) else { throw TravelFailure("地点已被修改，请重新读取确认。") }
    }
    private func notInUse(_ id: UUID) throws {
        guard !records.reminders.contains(where: { $0.place.id == id && $0.reservesPlace }) else {
            throw TravelFailure("此地点还有已安排或结果未知的提醒，请先取消它们再修改/删除地点，避免悄悄改变到家提醒。")
        }
    }
    /// Read-only reconciliation: never recreates a request that may have already fired.
    func refresh() async throws {
        try ready(); guard !busy else { throw TravelFailure("地点操作执行中，请稍后查询。") }
        busy = true; defer { busy = false }; let token = generation
        var next = records
        for i in next.reminders.indices where next.reminders[i].reservesPlace && next.reminders[i].state != .cancelling {
            let state = try await device.status(next.reminders[i]); try ready(token)
            switch state {
            case .scheduled: next.reminders[i].state = .scheduled
            case .delivered: next.reminders[i].state = next.reminders[i].repeats ? .unknown : .delivered
            case .missing: next.reminders[i].state = .unknown
            }
        }
        try save(next)
    }
    func apply(_ change: TravelChange, operationID: UUID) async throws -> String {
        if case .access(false) = change {
            allowed = false; generation = UUID(); candidates = []; routes = [:]
            return "已关闭后续地点对话访问；已安排的系统地点提醒仍保留，需另行取消。已发送资料不能撤回。"
        }
        guard !failed, !busy else { throw TravelFailure("地点操作尚未完成或本地记录不可读。") }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        if case .access(true) = change {
            allowed = true
            return "已允许本次运行按需把地点名称、地址和路线摘要用于当前模型；坐标保留本机，查找/路线请求会发给苹果地图。未请求定位，重启需重新许可。"
        }
        try ready(); let token = generation
        guard !transientConsumed.contains(operationID), !records.consumed.contains(operationID), !records.reminders.contains(where: { $0.id == operationID }) else {
            return "此确认已有记录，未重复执行。请查询系统状态；缺失不等于已提醒，不能自动重建。"
        }
        switch change {
        case .current:
            let p = try await device.current(); try ready(token); try p.validate()
            candidates = Array((candidates + [p]).suffix(40)); transientConsumed.insert(operationID)
            return "已取得本次位置候选：\(p.id)。\(p.name)；\(p.address)。这不是家的标记；只有你明确确认保存为家才会保存。"
        case .save(let alias, var p, let before):
            try p.validate()
            guard (1...40).contains(alias.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw TravelFailure("地点称呼须为1–40字。") }
            if let before { try checkPlace(before); try notInUse(before.id) }
            guard !records.places.contains(where: { $0.alias.localizedCaseInsensitiveCompare(alias) == .orderedSame && $0.id != before?.id }) else {
                throw TravelFailure("已有同名地点，请先读取编号并明确修改，不能覆盖或猜测。")
            }
            p.measuredAt = nil
            let saved = SavedPlace(id: before?.id ?? operationID, revision: (before?.revision ?? 0) + 1, alias: alias, point: p)
            var next = records; next.places.removeAll { $0.id == saved.id }; next.places.append(saved)
            next.consumed.insert(operationID); try save(next)
            return "已在本机保存「\(alias)」：\(p.name)，\(p.address)。未创建提醒，也不持续定位。"
        case .remove(let before):
            try checkPlace(before); try notInUse(before.id)
            var next = records; next.places.removeAll { $0.id == before.id }; next.consumed.insert(operationID); try save(next)
            return "已删除本机地点「\(before.alias)」。历史对话不会自动删除。"
        case .remind(let place, let text, let radius, let repeats):
            try checkPlace(place)
            var reminder = PlaceReminder(id: operationID, place: place, text: text, radius: radius, repeats: repeats, state: .attempting)
            try reminder.validate()
            guard records.reminders.filter(\.reservesPlace).count < 10 else { throw TravelFailure("最多保留10个活动或待核对的地点提醒，请先取消不需要的提醒。") }
            guard !records.reminders.contains(where: { $0.reservesPlace && $0.place.id == place.id && $0.text == text }) else {
                throw TravelFailure("此地点已有同内容的提醒，请先查询并取消旧项后再更改，避免重复提醒。")
            }
            try await device.authorizeReminder(); try ready(token); try checkPlace(place)
            var next = records; next.reminders.append(reminder); try save(next)
            do {
                try await device.schedule(reminder); try ready(token)
                guard try await device.status(reminder) == .scheduled else { throw TravelFailure("系统未返回对应请求。") }
                try ready(token); reminder.state = .scheduled; try replace(reminder)
            } catch {
                throw TravelFailure("地点提醒\(reminder.id)的安排结果需核对，可能已生效；不会重试或替换成定时提醒。请查询，必要时确认取消。")
            }
            return "系统已接收进入「\(place.alias)」周围\(Int(radius))米的\(repeats ? "重复" : "一次")提醒。已在范围内时等待离开后再次进入；可能延迟，不保证精确到门口。系统接收不代表已经提醒或任务完成。"
        case .cancel(let id):
            guard var reminder = records.reminders.first(where: { $0.id == id }) else { throw TravelFailure("找不到地点提醒。") }
            reminder.state = .cancelling; try replace(reminder)
            try await device.cancel(reminder)
            // Cancellation is allowed to finish even if dialogue consent is revoked while awaiting.
            guard try await device.status(reminder) == .missing else { throw TravelFailure("取消尚未核实，可再次确认取消；不会重新安排。") }
            reminder.state = .cancelled; try replace(reminder)
            return "已移除该地点提醒的待发及通知中心记录；不表示提醒事项已完成。已出现过的横幅无法撤回。"
        case .navigate(let route):
            guard (0...900).contains(Date.now.timeIntervalSince(route.checkedAt)) else { throw TravelFailure("路线已过期，请重新查询再打开地图。") }
            try route.origin.validate(); try route.destination.validate()
            var next = records; next.consumed.insert(operationID); try save(next)
            try await device.navigate(route)
            return "已请求苹果地图打开指定起终点路线；未设置提醒，不代表已经开始导航或按预计时间到达。"
        case .access: break
        }
        return ""
    }
    private func replace(_ value: PlaceReminder) throws {
        var next = records; next.reminders = next.reminders.map { $0.id == value.id ? value : $0 }; try save(next)
    }
    private func save(_ next: Records) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic); records = next
    }
}
