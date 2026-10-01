import Foundation

extension ButlerTools {
    static var taskDisplayTools: String {
        let string: [String: Any] = ["type": "string"]
        let tools = [
            functionSchema("get_task_displays", "查询本设备任务实时活动、系统开关和限制；会核对并结束过期/任务已改变的旧展示，绝不自动开启或重建。task_id=null返回最近100条；指定task_id可查询该任务的全部展示记录。展示状态不是任务状态，也不能证明锁屏实际可见。", ["task_id": ["type": ["string", "null"]]]),
            functionSchema("propose_start_task_display", "仅在用户明确要求锁屏/灵动岛展示时提出开启已有任务的限时展示；先get_tasks读取id/revision。until是带偏移的ISO8601时间，必须根据用户意图明确，不超过8小时或任务自动结束时间。窗口到期不代表任务完成，不更改提醒规则，重复任务也只展示这一个窗口。默认不显示任务名称，只有时间/状态；不等于响铃。修改、暂停、完成/取消任务会结束旧展示，恢复不会自动开启。", ["task_id": string, "expected_revision": ["type": "integer"], "until": string]),
            functionSchema("propose_end_task_display", "用户确认后只关闭指定实时活动，不完成/取消任务，也不停止闹钟。先get_task_displays获取准确task_id和session_id；任务已删除也可结束原展示。", ["task_id": string, "session_id": string])
        ]
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: ",")
    }

    func executeTaskDisplayTool(_ name: String, data: Data) async throws -> String? {
        switch name {
        case "get_task_displays":
            struct Args: Decodable { let task_id: UUID? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            var warning: String?
            do { try await taskDisplays.reconcile(tasks: TaskDisplayService.tasks(reminders)) }
            catch { warning = error.localizedDescription }
            let all = try taskDisplays.read().filter { args.task_id == nil || $0.taskID == args.task_id }
            let selected = args.task_id == nil ? Array(all.suffix(100)) : all
            let rows = selected.map { record -> [String: Any] in
                ["session_id": record.id.uuidString, "task_id": record.taskID.uuidString, "task_revision": record.revision,
                 "until": ISO8601DateFormatter().string(from: record.deadline), "state": record.state.rawValue,
                 "system_id": record.systemID as Any? ?? NSNull()]
            }
            return try encode(["enabled": taskDisplays.enabled, "records": rows, "total": all.count,
                               "truncated": all.count > rows.count, "warning": warning as Any? ?? NSNull(),
                               "max_hours": 8, "shows_task_names": false, "starts_in_foreground": true,
                               "note": "展示可被系统或用户移除；不会自动恢复。后台无法保证准时结束，到期显示资料过期，不等于任务完成。"] as [String: Any])
        case "propose_start_task_display":
            struct Args: Decodable { let task_id: UUID; let expected_revision: Int; let until: String }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let deadline = try Self.calendarDate(args.until)
            let change = TaskDisplayChange(action: .start, taskID: args.task_id, expectedRevision: args.expected_revision, deadline: deadline, sessionID: nil)
            try taskDisplays.validate(change, tasks: TaskDisplayService.tasks(reminders))
            let title = reminders.reminder(id: args.task_id)?.text ?? "任务"
            add(.taskDisplay(change), title: "开启「\(title)」的限时展示",
                detail: "展示至\(args.until)，锁屏只显示时间/状态，不显示名称。不会响铃或修改任务；任务改变后结束展示，后台到期不保证立即移除。")
        case "propose_end_task_display":
            struct Args: Decodable { let task_id: UUID; let session_id: UUID }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let change = TaskDisplayChange(action: .end, taskID: args.task_id, expectedRevision: nil, deadline: nil, sessionID: args.session_id)
            try taskDisplays.validate(change, tasks: [])
            add(.taskDisplay(change), title: "关闭任务实时活动", detail: "只移除展示，不完成或取消任务，也不停止闹钟。")
        default: return nil
        }
        return #"{"proposed":true,"saved":false,"confirmation_required":true}"#
    }
}
