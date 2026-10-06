import Foundation

extension ButlerTools {
    static var syncTools: String {
        let key: [String: Any] = ["kind": ["type": "string", "enum": ["inventory", "task", "note", "chat", "itemPhoto", "chatPhoto"]], "id": ["type": "string"]]
        let scope: [String: Any] = ["scope": ["type": "string", "enum": ["content", "chat", "photos"]]]
        let tools = [
            functionSchema("get_sync_status", "查询本机同步状态，不登录、不上传。成功只代表上次本轮完成，不代表另一设备已收到。", [:]),
            functionSchema("propose_sync_enabled", "明确请求后提议开启/关闭iCloud同步。开启库存文字、任务、笔记；聊天和图片分别单独开启。关闭会同时暂停聊天和图片，不删除任一端。", ["enabled": ["type": "boolean"]]),
            functionSchema("propose_chat_sync_enabled", "用户明确要求后单独提议同步聊天文字，默认关闭；只含已保存问答/历史回执与附件文件名，不含图片文件、草稿、待执行操作、健康查询结果或密钥。先开启普通同步，每台设备分别确认。", ["enabled": ["type": "boolean"]]),
            functionSchema("propose_photo_sync_enabled", "明确请求后单独提议同步Butler内已保存的物品图片和已发送聊天附件，默认关闭，不扫描相册，不传草稿和分享收件箱原件。单图4MB、每条问答最多4张、每边最长4096像素。先开启普通同步。", ["enabled": ["type": "boolean"]]),
            functionSchema("propose_sync_cleanup", "用户明确要求后读取指定云端范围，预览并单独确认清理。history仅清旧版本、保留当前及冲突分支；everything清空所选区。content为库存/任务/笔记，chat为聊天文字，photos为图片，不能将单区成功说成全部清空。本机保留，不能自动重开同步。中断时在原设备同范围继续原操作。", scope.merging(["mode": ["type": "string", "enum": ["history", "everything"]]]) { _, new in new }),
            functionSchema("propose_sync_reconnect", "云端清理后单独确认重新连接指定范围。明确告知当前本机资料会重新上传，可能恢复先前清掉的内容；不是单纯重试。", scope),
            functionSchema("sync_now", "仅已确认开启后尝试一轮双向同步，可能上传本地更改并接收云端资料；不自动解决冲突。", [:]),
            functionSchema("get_sync_conflicts", "列出本机已发现的冲突编号和类别；不联系云端，不把空结果当云端一定无冲突。", [:]),
            functionSchema("get_sync_conflict", "按编号查看冲突各版本，包括删除版本。库存一个商品及其批次作为一组，不擅自挑版本。", key),
            functionSchema("propose_sync_resolution", "用户明确选择一个已展示的版本后提出解决冲突。确认卡列出全部版本；后续新冲突不会被本次选择覆盖。", key.merging(["selected_version": ["type": "string"]]) { _, new in new })
        ]
        return ToolSchema.json(tools)
    }
    func syncStore(kind: SyncRecord.Kind = .note) throws -> SyncStore {
        guard let store = kind.isPhoto ? photoSynchronization : (kind == .chat ? chatSynchronization : synchronization) else { throw SyncFailure("本机同步尚未准备好；请检查本地记录和iCloud构建配置，未上传资料。") }
        return store
    }
    func executeSyncTool(_ name: String, data: Data) async throws -> String? {
        guard ["get_sync_status", "propose_sync_enabled", "propose_chat_sync_enabled", "propose_photo_sync_enabled", "propose_sync_cleanup", "propose_sync_reconnect", "sync_now", "get_sync_conflicts", "get_sync_conflict", "propose_sync_resolution"].contains(name) else { return nil }
        if name == "get_sync_status" {
            var status: [String: Any] = ["ready": synchronization != nil, "enabled": synchronization?.enabled ?? false,
                "busy": synchronization?.busy ?? false, "pending_revisions": synchronization?.pendingCount ?? 0,
                "last_success": synchronization?.lastSuccess?.ISO8601Format() as Any? ?? NSNull(),
                "warning": synchronization?.warning as Any? ?? NSNull(),
                "needs_reconnect": synchronization?.needsReconnect ?? false,
                "cleanup_operation": synchronization?.cleanupID?.uuidString as Any? ?? NSNull()]
            status.merge([
                "chat_enabled": (synchronization?.enabled ?? false) && (chatSynchronization?.enabled ?? false),
                "chat_last_success": chatSynchronization?.lastSuccess?.ISO8601Format() as Any? ?? NSNull(),
                "chat_warning": chatSynchronization?.warning as Any? ?? NSNull(),
                "chat_pending_revisions": chatSynchronization?.pendingCount ?? 0,
                "chat_needs_reconnect": chatSynchronization?.needsReconnect ?? false,
                "chat_cleanup_operation": chatSynchronization?.cleanupID?.uuidString as Any? ?? NSNull()
            ]) { _, new in new }
            status.merge([
                "photos_enabled": (synchronization?.enabled ?? false) && (photoSynchronization?.enabled ?? false),
                "photos_last_success": photoSynchronization?.lastSuccess?.ISO8601Format() as Any? ?? NSNull(),
                "photos_warning": photoSynchronization?.warning as Any? ?? NSNull(),
                "photos_needs_reconnect": photoSynchronization?.needsReconnect ?? false,
                "photos_cleanup_operation": photoSynchronization?.cleanupID?.uuidString as Any? ?? NSNull(),
                "scope": "库存文字、任务、笔记；聊天文字和图片分别单独许可。仅前台尽力同步，收到任务不新增本机通知。关闭不删除云端。"
            ]) { _, new in new }
            return try encode(status)
        }
        let store = try syncStore(), change: SyncChange, title: String, detail: String
        if name == "propose_sync_cleanup" || name == "propose_sync_reconnect" {
            struct Args: Decodable { let scope: String; let mode: SyncCleanup.Mode? }
            let args = try JSONDecoder().decode(Args.self, from: data)
            guard ["content", "chat", "photos"].contains(args.scope) else { throw SyncFailure("请选择普通资料、聊天文字或图片范围。") }
            let kind: SyncRecord.Kind = args.scope == "photos" ? .itemPhoto : (args.scope == "chat" ? .chat : .inventory)
            let target = try syncStore(kind: kind), label = args.scope == "photos" ? "图片" : (args.scope == "chat" ? "聊天文字" : "库存、任务和笔记")
            if name == "propose_sync_cleanup" {
                guard let mode = args.mode else { throw SyncFailure("请明确只清旧版本还是清空所选云端区。") }
                var plan = try await target.previewCleanup(mode)
                if let old = pending.compactMap({ proposal -> SyncCleanup? in
                    if case .sync(.cleanup(let previousKind, let previous)) = proposal.kind,
                       previousKind == kind, previous.mode == mode, previous.head == plan.head { return previous }
                    return nil
                }).first { plan = old }
                change = .cleanup(kind: kind, plan: plan)
                title = mode == .history ? "清理\(label)的云端旧版本" : "清空\(label)云端区"
                detail = "范围仅为\(label)，不是其他同步区。当前云端\(plan.removed.count)个版本；完成后保留\(plan.retained.count)个当前版本、删除标记或未解决冲突分支。旧版本不能再通过Butler恢复；苹果底层图片存储回收可能延迟，不承诺立即物理擦除。本机资料不删，该区停止同步；清理普通资料也暂停本机聊天与图片，但不删除那两个区。其他设备下次连接须核对换代，不会自动传回旧内容。\(target.cleanupID == nil ? "这是新的清理预览。" : "核对并继续上次中断的同一清理操作。")操作编号：\(plan.id.uuidString)。云端变化则拒绝旧预览，完成后重新上传须另行确认。"
            } else {
                let (account, head) = try await target.reconnectPreview()
                change = .reconnect(kind: kind, account: account, head: head)
                title = "重新连接\(label)并允许上传本机资料"
                detail = "将本机当前\(label)与清理后的当前云端重新核对，前台上传和接收；可能把你先前清掉的内容重新存回云端。只重建当前内容，不重传本机同步日志里的旧版本。有差异保留冲突，不覆盖本机。此次只开启所选范围，其他范围不自动恢复。"
            }
        } else if name == "propose_sync_enabled" {
            struct Args: Decodable { let enabled: Bool }
            let enabled = try JSONDecoder().decode(Args.self, from: data).enabled
            change = .enabled(enabled); title = enabled ? "开启iCloud跨设备同步" : "关闭本机iCloud同步"
            detail = enabled
                ? "将当前及后续库存文字资料、任务和笔记保存至当前iCloud账户的私有空间，并接收同账户的更改。聊天和图片分别另外确认开启；密钥、系统授权、健康结果、闹钟和地点提醒不上传。云端文字可按需用于已有对话查询。冲突先保留版本再询问，收到的任务不自动新增通知；仅前台尽力同步，不保证实时。历史版本暂保留，普通删除不等于抹除云端历史。"
                : "停止普通资料、聊天和图片后续同步；再次开启普通同步不会自动重开聊天或图片。本机与云端已有资料均保留，已经发出的请求可能完成，不会撤回上传。其他设备不受影响。"
        } else if name == "propose_photo_sync_enabled" {
            struct Args: Decodable { let enabled: Bool }
            let enabled = try JSONDecoder().decode(Args.self, from: data).enabled
            _ = try syncStore(kind: .itemPhoto)
            change = .photosEnabled(enabled); title = enabled ? "单独开启Butler图片同步" : "关闭图片同步"
            detail = enabled
                ? "上传和接收Butler内已保存的物品图片及已发送聊天附件，包括图片原有内容/元数据和所属编号；不扫描手机相册，不上传草稿或分享收件箱原件。图片可能包含敏感信息。聊天文字需另外许可，图片先到会暂存，等所属内容到齐后显示；不会自动把图片发送AI识别。当前对话结束后前台尽力同步，每台设备分别开启；会使用网络与iCloud空间。单图最多4MB/4096像素，每条问答最多4张；超限停止，不自动缩图丢质量。普通删除仍保留云端旧版本。"
                : "停止后续图片上传和接收；本机、云端已有图片及旧版本均保留，已发请求可能完成。普通资料和聊天文字开关不受影响。"
        } else if name == "propose_chat_sync_enabled" {
            struct Args: Decodable { let enabled: Bool }
            let enabled = try JSONDecoder().decode(Args.self, from: data).enabled
            _ = try syncStore(kind: .chat)
            change = .chatEnabled(enabled); title = enabled ? "单独开启聊天文字同步" : "关闭聊天文字同步"
            detail = enabled
                ? "上传当前及后续已保存的各会话问答、历史回执和关联编号至当前iCloud私有空间，并接收同账户的聊天。你曾在对话中输入或同意读取的个人信息也可能包含其中；接收的文字会进入已有对话上下文、按需发送当前模型。只传附件文件名，不传图片文件；草稿、待确认操作、密钥、授权、健康查询结果和旧摘要不传。历史里的确认文字不会被重新执行。正在进行的对话结束后才同步；每台设备分别开启，普通删除保留云端历史，不等于彻底擦除。"
                : "停止后续聊天上传和接收，不影响普通资料同步；已有本机、云端聊天及历史版本保留，已发请求可能完成。"
        } else if name == "sync_now" {
            do { try await store.synchronize() }
            catch { throw SyncFailure(store.warning ?? "本轮同步未完成，本机资料保留。") }
            // This tool usually runs inside an active conversation. History imports wait
            // for idle rather than overwriting the answer that is currently being produced.
            return try encode(["base_round_completed": true, "conflicts": try store.conflicts().count,
                "chat": chatSynchronization?.enabled == true ? "当前对话结束后前台自动尝试；本次未同步聊天" : "未开启",
                "photos": photoSynchronization?.enabled == true ? "当前对话结束后前台自动尝试；本次未同步图片" : "未开启",
                "other_device_received": NSNull()] as [String: Any])
        } else if name == "get_sync_conflicts" {
            let conflicts = try store.conflicts() + (chatSynchronization?.conflicts() ?? []) + (photoSynchronization?.conflicts() ?? [])
            return try encode(conflicts.map { rows in
                ["kind": rows[0].key.kind.rawValue, "id": rows[0].key.id.uuidString, "versions": rows.count] as [String: Any]
            })
        } else {
            struct Args: Decodable { let kind: SyncRecord.Kind; let id: UUID; let selected_version: UUID? }
            let args = try JSONDecoder().decode(Args.self, from: data), key = SyncRecord.Key(kind: args.kind, id: args.id)
            guard let rows = try syncStore(kind: args.kind).conflicts().first(where: { $0[0].key == key }) else { throw SyncFailure("此冲突已变化，请重新查询。") }
            let versions = try rows.map { row -> [String: Any] in
                ["version_id": row.id.uuidString, "deleted": row.payload == nil,
                 "source_device": row.device.uuidString, "from_this_device": row.device == (try syncStore(kind: args.kind)).deviceID,
                 "content": try row.payload.map { row.key.kind.isPhoto ? try Self.syncPreview(row) as Any : try JSONSerialization.jsonObject(with: $0) } ?? NSNull()]
            }
            let contents = try encode(versions)
            guard contents.utf8.count <= 24_000 else { throw SyncFailure("此冲突明细过大，暂不能安全展示全部差异；保留版本，未自动选择。") }
            if name == "get_sync_conflict" { return contents }
            guard let selected = args.selected_version, rows.contains(where: { $0.id == selected }) else { throw SyncFailure("请从展示的版本中明确选择。") }
            change = .resolve(key: key, heads: Set(rows.map(\.id)), selected: selected)
            title = "确认冲突保留版本 \(selected.uuidString.prefix(8))"
            let previews = try rows.map { "版本 \($0.id.uuidString.prefix(8))\n\(try Self.syncPreview($0))" }.joined(separator: "\n\n")
            detail = "选择该版本作为完整当前内容（删除版本会移除当前条目，所选版本未列出的可选内容会清除）；原分支仍在同步历史中。聊天和图片选择将在当前对话结束后核对新变化再采用。图片仅显示来源与文件信息，请在来源设备核对实际图片后选择，不能根据大小猜内容。\n\(previews)"
        }
        if !pending.contains(where: { if case .sync(let old) = $0.kind { old == change } else { false } }) {
            add(.sync(change), title: title, detail: detail)
        }
        return #"{"proposed":true,"confirmation_required":true}"#
    }

    /// A readable confirmation, not epoch timestamps and base64 profile blobs.
    private static func syncPreview(_ record: SyncRecord) throws -> String {
        guard let payload = record.payload else { return "删除此条目" }
        if record.key.kind.isPhoto {
            let bundle = try JSONDecoder().decode(SyncPhotoBundle.self, from: payload)
            try bundle.validate(for: record.key)
            return "来源设备：\(record.device.uuidString)；所属编号：\(record.key.id.uuidString)\n"
                + bundle.files.map { "\($0.name)：\($0.data.count)字节（图片内容未交给模型）" }.joined(separator: "\n")
        }
        let labels = ["product": "商品", "lots": "批次", "templates": "常用设置", "canonicalName": "名称", "brand": "品牌",
            "categoryRawValue": "类别", "barcode": "条码", "defaultUnit": "默认单位", "quantity": "数量", "unit": "单位",
            "storageLocation": "存放位置", "stateRawValue": "状态", "title": "标题", "text": "内容", "status": "状态",
            "fireDate": "提醒时间", "createdAt": "创建时间", "updatedAt": "修改时间", "endDate": "结束时间",
            "autoCompleteAt": "自动结束", "purchasedAt": "购买时间", "packageExpiryDate": "包装有效期",
            "estimatedExpiryDate": "预计到期", "plannedUseByDate": "计划用完", "repeats": "重复方式",
            "timeZoneIdentifier": "时区", "phases": "阶段", "activity": "操作记录", "profileData": "物品资料",
            "category": "类别", "attributes": "属性", "tags": "标签", "availability": "使用状态", "id": "编号",
            "productID": "商品编号", "revision": "本机版本（不同步）", "detail": "说明", "date": "时间", "kind": "类型",
            "question": "用户原话", "answer": "管家回答", "receipts": "历史操作回执（不会重做）", "scope": "所属会话", "photos": "附件文件名（不含图片）"]
        let dates: Set<String> = ["fireDate", "createdAt", "updatedAt", "endDate", "autoCompleteAt", "purchasedAt", "packageExpiryDate", "estimatedExpiryDate", "plannedUseByDate", "date", "startDate"]
        func render(_ value: Any, key: String = "", indent: String = "") throws -> String {
            if key == "profileData", let raw = value as? String, let data = Data(base64Encoded: raw) {
                return try render(JSONSerialization.jsonObject(with: data), indent: indent)
            }
            if dates.contains(key), let seconds = value as? Double { return Date(timeIntervalSinceReferenceDate: seconds).ISO8601Format() }
            if let object = value as? [String: Any] {
                return try object.keys.sorted().map { "\(indent)\(labels[$0] ?? $0)：\(try render(object[$0]!, key: $0, indent: indent + "  "))" }.joined(separator: "\n")
            }
            if let array = value as? [Any] { return try array.map { try render($0, indent: indent + "  ") }.joined(separator: "\n") }
            return String(describing: value)
        }
        return try render(JSONSerialization.jsonObject(with: payload))
    }
}
