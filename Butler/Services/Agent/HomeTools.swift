import Foundation

extension ButlerTools {
    static var homeTools: String {
        let string: [String: Any] = ["type": "string"]
        let tools = [
            functionSchema("get_home_capabilities", "查询家庭接口范围和本次运行的对话许可，不启动系统家庭授权。", [:]),
            functionSchema("propose_home_access", "提议允许/关闭本次运行期间的家庭资料对话访问，须用户确认。允许后按请求把相关家庭/房间/设备名称及状态发给当前模型；历史不能撤回。控制仍逐次确认。", ["allowed": ["type": "boolean"]]),
            functionSchema("get_homes", "许可后列出家庭编号/名称，不按同名猜测目标。", [:]),
            functionSchema("get_home_details", "按家庭编号查询支持的属性与场景，每页各最多30项，offset从0开始。缓存值不是当前实况；用read_home_control读状态。场景可能含不支持的动作。", ["home_id": string, "offset": ["type": "integer"]]),
            functionSchema("read_home_control", "读取一个准确属性的当前报告值。lock/garage/security为目标设置，不代表实际动作完成；实际状态用currentLock/currentDoor/currentSecurity，障碍用obstruction。离线/无值不当作关闭。", ["home_id": string, "control_id": string]),
            functionSchema("propose_home_control", "按明确意图提议单个属性目标：power 0关1开，brightness 0–100，lock 0解锁1上锁，garage 0开1关，security 0居家1离家2夜间3撤防。只能用查询得到的编号，不支持温控写入。高风险必须单独确认。", ["home_id": string, "control_id": string, "target": ["type": "number"]]),
            functionSchema("propose_home_scene", "提议场景完整动作，确认前后核对内容。逐项执行非原子，部分失败不重试/回滚。混合高风险与普通动作、重复属性、未知动作或超过20项的场景拒绝，不擅自省略。", ["home_id": string, "scene_id": string]),
            functionSchema("get_home_operations", "查看最近50次确认的尝试/读回计数；不是设备当前状态，未完成可能已生效。不能自动重试。", [:])
        ]
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: ",")
    }

    func executeHomeTool(_ name: String, data: Data) async throws -> String? {
        switch name {
        case "get_home_capabilities":
            return try encode(["conversation_access": home.allowed, "writes": ["power", "brightness", "lock", "garage", "security"],
                "note": "仅对话提议与确认；无自动化/后台执行。重启需重新许可。缓存值不是当前状态。"] as [String: Any])
        case "propose_home_access":
            struct Args: Decodable { let allowed: Bool }
            let args = try JSONDecoder().decode(Args.self, from: data)
            if pending.contains(where: { if case .home(.access(args.allowed)) = $0.kind { true } else { false } }) { break }
            add(.home(.access(args.allowed)), title: args.allowed ? "允许家庭资料用于当前模型对话" : "关闭家庭对话访问",
                detail: "本次运行按请求提供相关家庭、房间、设备名称和状态给当前配置的模型，内容可能进入对话历史。重启需重新许可；关闭不能撤回已发送内容或正在发出的指令。每次控制仍需确认。")
        case "get_homes":
            let homes = try home.homes()
            return try encode(["homes": homes.prefix(100).map { ["id": $0.0.uuidString, "name": $0.1] }, "truncated": homes.count > 100] as [String: Any])
        case "get_home_details":
            struct Args: Decodable { let home_id: UUID; let offset: Int }
            let args = try JSONDecoder().decode(Args.self, from: data)
            guard args.offset >= 0 else { throw HomeFailure("offset不能为负数。") }
            let snapshot = try await home.snapshot(args.home_id)
            let page = HomeSnapshot(id: snapshot.id, name: snapshot.name, rooms: [],
                controls: Array(snapshot.controls.dropFirst(args.offset).prefix(30)),
                scenes: snapshot.scenes.dropFirst(args.offset).prefix(30).map {
                    HomeScene(id: $0.id, name: $0.name, actions: [], unsupportedActions: $0.unsupportedActions)
                })
            // Avoid including every scene's device data in a broad discovery request.
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page))
            return try encode(["page": value, "control_count": snapshot.controls.count, "scene_count": snapshot.scenes.count,
                "note": "房间见每项属性。场景此处省略动作；提议时展示完整动作。value是缓存，仅供发现，不能当当前实况。每页30项。"] as [String: Any])
        case "read_home_control":
            struct Args: Decodable { let home_id: UUID; let control_id: UUID }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let snapshot = try await home.snapshot(args.home_id)
            guard let control = snapshot.controls.first(where: { $0.id == args.control_id }) else { throw HomeFailure("找不到属性。") }
            let value = try await home.read(homeID: args.home_id, controlID: args.control_id)
            return try encode(["control_id": control.id.uuidString, "kind": control.kind.rawValue,
                "reported_value": value as Any? ?? NSNull(), "read_at": ISO8601DateFormatter().string(from: .now),
                "note": "设备报告值，不保证现实状态。currentLock:0未锁1锁定2卡住3未知；currentDoor:0打开1关闭2正在打开3正在关闭4停止；currentSecurity:0居家1离家2夜间3撤防4触发警报；obstruction:1有障碍0未报告。其他枚举值视为未知。"] as [String: Any])
        case "propose_home_control", "propose_home_scene":
            struct Args: Decodable { let home_id: UUID; let control_id: UUID?; let target: Double?; let scene_id: UUID? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            guard (name == "propose_home_scene") == (args.scene_id != nil) else { throw HomeFailure("工具与操作类型不符。") }
            let snapshot = try await home.snapshot(args.home_id)
            let plan = try HomeStore.plan(snapshot, controlID: args.control_id, target: args.target, sceneID: args.scene_id)
            if pending.contains(where: {
                if case .home(.execute(let old)) = $0.kind { old.signature == plan.signature } else { false }
            }) { break }
            let detail = plan.actions.map { "\($0.control.label)：\($0.control.targetLabel($0.target))" }.joined(separator: "\n")
            add(.home(.execute(plan)), title: "\(plan.risky ? "高风险·单独确认" : "控制家庭")：\(plan.homeName) / \(plan.sceneName ?? plan.actions[0].control.accessory)",
                detail: detail + "\n逐项执行，非同时生效。部分成功不自动回滚或重试，读回目标不保证实际动作完成。")
        case "get_home_operations":
            return try encode(try home.operations().suffix(50).map {
                ["operation_id": $0.id.uuidString, "home_id": $0.homeID.uuidString, "attempted": $0.attempted,
                 "matched_target": $0.matched, "finished": $0.finished, "total": $0.actions.count] as [String: Any]
            })
        default: return nil
        }
        return #"{"proposed":true,"saved":false,"confirmation_required":true}"#
    }
}
