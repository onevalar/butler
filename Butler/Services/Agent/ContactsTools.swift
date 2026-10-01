import Foundation

extension ButlerTools {
    static var contactsTools: String {
        let string: [String: Any] = ["type": "string"]
        let values: [String: Any] = ["type": "array", "maxItems": 20, "items": ["type": "object",
            "properties": ["label": ["type": ["string", "null"]], "value": string],
            "required": ["label", "value"], "additionalProperties": false]]
        let tools = [
            functionSchema("get_contacts_capabilities", "查询可选通讯录能力及授权状态，不请求系统权限。未使用者不提示开启。", [:]),
            functionSchema("propose_contacts_access", "仅在用户要求通讯录操作时提议本次运行对话许可。获准后姓名搜索只返回候选姓名/单位；选择并确认后才读取所需电话/邮箱等字段给当前模型。关闭不影响其他功能，不能撤回历史。", ["allowed": ["type": "boolean"]]),
            functionSchema("search_contacts", "许可后按具体姓名查询最多20个候选，仅姓名、单位和编号，无电话邮箱。同名须询问用户选择；受限授权的空结果不代表整本通讯录无人。不能空白查询或导出整本通讯录。", ["name": string]),
            functionSchema("propose_contact_read", "选择search_contacts返回的准确联系人，提议读取一个必要字段给当前模型，用户确认后才读取。回执含selection和token供修改。不同联系人/字段分别确认，不自动读取所有候选详情。", ["id": string, "field": ["type": "string", "enum": ContactField.allCases.map(\.rawValue)]]),
            functionSchema("propose_contact_create", "确认后在系统默认账户创建联系人，可能随该账户同步。仅写明确提供的姓名、单位、电话和邮箱；未知文本填空串、列表填空数组，不猜号码。会检查同名候选，已有同名不等于同一人，必须明确新建。", ["givenName": string, "familyName": string, "organization": string, "phones": values, "emails": values]),
            functionSchema("propose_contact_update", "只替换最近确认读取的一个字段，token来自读取回执；values是完整的新字段值，不是追加。添加号码时保留原有号码和标签。电话/邮箱空数组清空该字段；姓名/单位须一个label=null的文本项。提案显示前后差异，外部变化后拒绝覆盖。", ["token": string, "values": values]),
            functionSchema("get_contact_operations", "查询最近50次写入状态及未知结果。不是联系人当前状态；未核实操作禁止自动重试。", [:]),
            functionSchema("propose_close_contact_operation", "仅在用户已在系统通讯录人工核对未知结果并要求结束等待时提议；确认后只解除写入等待，仍标记未核实，不重新写入或回滚。", ["operation_id": string])
        ]
        return tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: ",")
    }
    func executeContactsTool(_ name: String, data: Data) throws -> String? {
        let change: ContactChange, title: String, detail: String
        func display(_ values: [ContactValue]) -> String {
            values.isEmpty ? "（清空）" : values.map { "\($0.label.map { "[\($0)] " } ?? "")\($0.value.isEmpty ? "（空）" : $0.value)" }.joined(separator: "；")
        }
        switch name {
        case "get_contacts_capabilities":
            return try encode(["optional": true, "conversation_access": contacts.allowed, "system_access": contacts.access.rawValue,
                "fields": ContactField.allCases.map(\.rawValue), "note": "不在启动时授权或自动读取。不支持删除联系人、整本导出、照片、备注、通话记录或短信。"] as [String: Any])
        case "propose_contacts_access":
            struct Args: Decodable { let allowed: Bool }
            let args = try JSONDecoder().decode(Args.self, from: data)
            change = .access(args.allowed)
            title = args.allowed ? "按需启用通讯录对话能力" : "关闭通讯录对话访问"
            detail = "可选功能，不使用不影响其他功能。本次运行按请求将候选姓名/单位及另行选择确认的字段发送给当前配置模型，可能保留在对话历史。只访问系统获准范围；关闭或重启停止后续访问，不能撤回已发送内容。创建、修改另行确认。"
        case "search_contacts":
            struct Args: Decodable { let name: String }
            let args = try JSONDecoder().decode(Args.self, from: data)
            let candidates = try contacts.search(args.name)
            return try encode(["candidates": try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidates)),
                "scope": contacts.access.rawValue, "note": "仅获准范围的匹配；同名先询问，不猜测身份，不自动读全部候选详情。"] as [String: Any])
        case "propose_contact_read":
            struct Args: Decodable { let id: String; let field: ContactField }
            let args = try JSONDecoder().decode(Args.self, from: data), candidate = try contacts.candidate(args.id)
            change = .read(candidate, args.field)
            title = "读取「\(candidate.name)」的\(args.field.title)"
            detail = "单位：\(candidate.organization)。只读取所选字段给当前模型，用于本次请求并可能进入历史；不修改联系人。"
        case "propose_contact_create":
            let draft = try JSONDecoder().decode(ContactDraft.self, from: data)
            change = try contacts.createProposal(draft)
            guard case .create(_, let ids) = change else { throw ContactFailure("提案类型错误。") }
            title = "新建联系人「\(draft.name)」"
            detail = ContactField.allCases.map { "\($0.title)：\(display(draft.values($0)))" }.joined(separator: "\n")
                + "\n在系统默认账户创建，可能随账户同步。获准范围内有\(ids.count)位姓名匹配候选；这是新建，不修改已有联系人。受限范围外的重复无法检查。"
        case "propose_contact_update":
            struct Args: Decodable { let token: UUID; let values: [ContactValue] }
            let args = try JSONDecoder().decode(Args.self, from: data)
            change = try contacts.updateProposal(token: args.token, values: args.values)
            guard case .update(let before, let after) = change else { throw ContactFailure("提案类型错误。") }
            title = "修改「\(before.candidate.name)」的\(before.field.title)"
            detail = "单位：\(before.candidate.organization)\n原值：\(display(before.values))\n新值：\(display(after))\n只替换这一字段，其他资料保留。可能随所属账户同步。"
        case "get_contact_operations":
            let operations = try contacts.operations()
            return String(decoding: try JSONEncoder().encode(Array(operations.suffix(50))), as: UTF8.self)
        case "propose_close_contact_operation":
            struct Args: Decodable { let operation_id: UUID }
            let args = try JSONDecoder().decode(Args.self, from: data)
            guard try contacts.operations().contains(where: { $0.id == args.operation_id && $0.state == .attempted }) else {
                throw ContactFailure("没有此结果未知的操作。")
            }
            change = .closeUnknown(args.operation_id)
            title = "人工核对后结束通讯录写入等待"
            detail = "请先在系统通讯录检查是否已生效。这里只解除等待，保留未核实标记，不重试、不回滚，也不表示原操作成功。"
        default: return nil
        }
        if !pending.contains(where: { if case .contacts(let old) = $0.kind { old == change } else { false } }) {
            add(.contacts(change), title: title, detail: detail)
        }
        return #"{"proposed":true,"saved":false,"confirmation_required":true}"#
    }
}
