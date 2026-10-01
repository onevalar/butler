import Foundation

extension ButlerTools {
    static var healthTools: String {
        let string: [String: Any] = ["type": "string"]
        let metric: [String: Any] = ["type": "string", "enum": HealthMetric.allCases.map(\.rawValue)]
        let writable: [String: Any] = ["type": "string", "enum": HealthMetric.allCases.filter(\.writable).map(\.rawValue)]
        let entry: [String: Any] = ["metric": writable, "value": ["type": "number"], "unit": string, "date": string]
        var correction = entry; correction["sample_id"] = string
        let schemas = [
            functionSchema("get_health_capabilities", "查询健康工具边界，不读取健康资料或申请权限。仅服务用户自身健康/健身管理，不用于广告、画像或医疗诊断。当前所有健康读取只本机展示，不提供发送AI接口。", [:]),
            functionSchema("propose_health_summary", "提出读取本机健康摘要，确认后才申请所选类型权限并读取。结果仅手机显示，模型拿不到数值；不能猜测结果或零数据。明确类型及start/end带时区ISO8601，每次最多31天，过去范围，end不包含；按范围内开始的样本合计。", ["metrics": ["type": "array", "items": metric, "minItems": 1, "maxItems": 8], "start": string, "end": string]),
            functionSchema("propose_own_health_records", "确认后在手机列出Butler自己写的健康记录，每次最多100条，超出需缩短时间。结果不返回模型。让用户从本机结果提供准确sample_id，不能猜编号或默认为最新记录。", ["metric": writable, "start": string, "end": string]),
            functionSchema("propose_health_record", "提出新增已经发生的饮水/营养记录，确认后写健康App。不把计划、建议、购买量或食物重量当成已摄入；value必须由用户明确提供，不能根据库存猜营养。water单位mL/L，dietaryEnergy单位kcal/kJ，protein/carbohydrates/fat单位g/mg。date须带偏移ISO8601，不允许未来时间。每项独立确认，部分成功不自动撤销。", entry),
            functionSchema("propose_health_correction", "纠正用户指定的Butler健康记录。sample_id来自本机查询后用户提供，不按标题猜测；提供完整替换值/单位/日期，不能改类型。确认后核对来源和原样本仍存在，以新版本替换，旧编号不再有效；不会先删除再新增，也不改其他来源。", correction),
            functionSchema("propose_health_delete", "确认后永久删除用户指定的Butler健康记录。必须提供准确sample_id和metric，不支持批量按范围删除，不改其他来源，不撤销任务或库存。", ["sample_id": string, "metric": writable]),
            functionSchema("get_health_operations", "只读最近100条本设备操作编号和状态，不读健康记录；pending不代表失败，不能重新提议相同写入。", [:]),
            functionSchema("propose_health_verification", "提出核对未知写入，用户确认后只查询该写入标识，绝不重新保存。查不到不能断言失败，删除丢回执不能靠空结果判断成功。", ["operation_id": string]),
            functionSchema("propose_close_health_verification", "只有用户明确表示已在健康App人工核对，并希望结束等待时才提议。确认后仅解除本机未知操作阻塞，状态为closedUnverified，不认定原操作成功或失败、不重试或撤销；以后的新记录仍可能重复，必须提醒。", ["operation_id": string])
        ]
        return schemas.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: ",")
    }

    func executeHealthTool(_ name: String, data: Data) throws -> String? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Self.calendarDate(decoder.singleValueContainer().decode(String.self))
        }
        let change: HealthChange
        let title: String
        let detail: String
        switch name {
        case "get_health_capabilities":
            return try encode(["available": health.available, "read_authorization": "not_disclosed_by_HealthKit",
                "read_types": HealthMetric.allCases.map(\.rawValue), "write_types": HealthMetric.allCases.filter(\.writable).map(\.rawValue),
                "sends_native_health_data_to_ai": false, "confirmation_each_read_and_write": true,
                "note": "读取结果仅本机临时显示，不进入模型、历史摘要或备份；无法保证健康App中全部数据可见，不做诊断。"] as [String: Any])
        case "get_health_operations":
            let all = try health.receipts()
            return try encode(["total": all.count, "operations": all.suffix(100).map {
                ["operation_id": $0.id.uuidString, "state": $0.state.rawValue]
            }] as [String: Any])
        case "propose_health_summary":
            struct Args: Decodable { let metrics: [HealthMetric]; let start: Date; let end: Date }
            let a = try decoder.decode(Args.self, from: data), range = HealthRange(start: a.start, end: a.end)
            change = .summary(a.metrics, range)
            title = "在手机查看健康摘要"
            detail = a.metrics.map(\.label).joined(separator: "、") + "\n" + range.label
        case "propose_own_health_records":
            struct Args: Decodable { let metric: HealthMetric; let start: Date; let end: Date }
            let a = try decoder.decode(Args.self, from: data), range = HealthRange(start: a.start, end: a.end)
            change = .ownRecords(a.metric, range)
            title = "查看Butler写入的健康记录"
            detail = a.metric.label + "\n" + range.label
        case "propose_health_record", "propose_health_correction":
            struct Args: Decodable { let metric: HealthMetric; let value: Double; let unit: String; let date: Date; let sample_id: UUID? }
            let a = try decoder.decode(Args.self, from: data)
            let entry = HealthEntry(metric: a.metric, value: try a.metric.canonical(a.value, unit: a.unit), date: a.date)
            if name == "propose_health_correction" {
                guard let id = a.sample_id else { throw HealthFailure("纠正必须指定原记录编号。") }
                change = .correct(id, entry); title = "纠正健康记录"
                detail = "原编号：\(id.uuidString)\n替换为：\(entry.label)"
            } else {
                guard a.sample_id == nil else { throw HealthFailure("新增不能带旧记录编号。") }
                change = .create(entry); title = "记录到健康App"; detail = entry.label
            }
        case "propose_health_delete":
            struct Args: Decodable { let sample_id: UUID; let metric: HealthMetric }
            let a = try decoder.decode(Args.self, from: data)
            change = .delete(a.sample_id, a.metric); title = "删除Butler健康记录"
            detail = "\(a.metric.label) · 编号：\(a.sample_id.uuidString)\n永久删除，不能撤销。其他来源不受影响。"
        case "propose_health_verification":
            struct Args: Decodable { let operation_id: UUID }
            let a = try decoder.decode(Args.self, from: data)
            change = .verify(a.operation_id); title = "核对健康操作"
            detail = "操作编号：\(a.operation_id.uuidString)\n只核对，不重复写入。"
        case "propose_close_health_verification":
            struct Args: Decodable { let operation_id: UUID }
            let a = try decoder.decode(Args.self, from: data)
            change = .closeVerification(a.operation_id); title = "结束健康操作核对"
            detail = "操作编号：\(a.operation_id.uuidString)\n请先在健康App人工核对。本次只解除等待，不认定结果、不重试或撤销；以后新增时请避免重复。"
        default: return nil
        }
        try change.validate()
        guard health.available else { throw HealthFailure("当前设备不支持健康数据。") }
        if !pending.contains(where: { if case .health(let value) = $0.kind { value == change } else { false } }) {
            add(.health(change), title: title, detail: detail + "\n仅用于健康管理；读取结果仅本机临时显示，不发送AI，重启后不保留。系统授权按需申请；此提案不跨重启保存。")
        }
        return #"{"proposed":true,"saved":false,"confirmation_required":true,"results_local_only":true}"#
    }
}
