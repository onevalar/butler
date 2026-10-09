import Foundation

/// Shares the chat's real stores, but never calls refresh methods that complete tasks or ask for permissions.
@MainActor
enum BriefSources {
    static func snapshot(tools: ButlerTools, now: Date, calendar: Calendar = .current) -> BriefContext {
        var context = BriefContext()
        var unavailable: [String: String] = [:]
        context.metadata["profile"] = tools.settingsDefaults.string(forKey: "butlerProfile") ?? ""
        context.metadata["time_zone"] = calendar.timeZone.identifier
        context.metadata["scope"] = "全部在库物品、全部本地任务（含暂停/完成状态）、全部已确认笔记；最近对话只作线索，可查历史原文。没有按类别或紧急程度筛选。"
        context.metadata["snoozed_targets"] = BriefSnoozes.active(now: now, defaults: tools.settingsDefaults).sorted()
        if let expiration = BriefSnoozes.nextExpiration(now: now, defaults: tools.settingsDefaults) { context.boundaries.append(expiration) }
        if let household = tools.householdContext() { context.metadata["household"] = household }
        do {
            context.sections["inventory"] = try tools.activeFacts().sorted { $0.id.uuidString < $1.id.uuidString }.map { lot in
                var row: [String: Any] = ["key": BriefTarget.lot(lot.id).key, "name": lot.name,
                    "quantity": lot.quantity, "unit": lot.unit,
                    "category": lot.category.rawValue, "quantity_only": lot.quantityOnly, "medicine": lot.isMedicine]
                row["brand"] = lot.brand
                row["storage"] = lot.storageLocation
                row["date"] = lot.governingDate?.isoDay
                row["date_kind"] = lot.governingDateKind?.rawValue
                row["attributes"] = lot.profile?.attributes
                row["availability"] = lot.profile?.availability
                row["tags"] = lot.profile?.tags
                return row
            }
        } catch { unavailable["inventory"] = "库存读取失败，不能当作家里没有物品" }
        do {
            context.sections["tasks"] = try tools.reminders.taskSnapshot().sorted { $0.id.uuidString < $1.id.uuidString }.map { task in
                var row = try json(task)
                row.removeValue(forKey: "activity")
                row.removeValue(forKey: "revision")
                row.removeValue(forKey: "sharing")
                if let family = tools.familyDescription(task) { row["family"] = family }
                row["key"] = BriefTarget.task(task.id).key
                let occurrences = ReminderSchedule.preview(task, now: now, limit: 3)
                context.boundaries += occurrences.filter { $0 > now }
                if let end = task.autoCompleteAt, end > now { context.boundaries.append(end) }
                row["next_occurrences"] = occurrences.map { $0.ISO8601Format() }
                row["occurrence_scope"] = "最多展示接下来3次；完整规则见 phases/repeats，不代表只有3次"
                return row
            }
        } catch { unavailable["tasks"] = "任务读取失败，不能当作没有安排" }
        do {
            context.sections["notes"] = try tools.notes.recordsForSync().sorted { $0.id.uuidString < $1.id.uuidString }.map {
                ["id": $0.id.uuidString, "title": $0.title, "text": $0.text, "quantity": $0.quantity as Any? ?? NSNull()]
            }
        } catch { unavailable["notes"] = "笔记读取失败或正在更新，不能把旧偏好当作最新交代" }
        if let archive = tools.conversation?() {
            context.metadata["conversation"] = archive.overview()
            if let error = archive.readError { unavailable["conversation"] = error }
            // A bounded recent window is a pointer, not a claim that older instructions do not exist.
            let start = max(1, archive.turns.count - 11)
            var recent: [[String: Any]] = []
            var cursor: Int?
            repeat {
                let page = archive.read(fromTurn: start, toTurn: nil, from: nil, to: nil, cursor: cursor)
                recent += page["turns"] as? [[String: Any]] ?? []
                cursor = page["next_cursor"] as? Int
            } while cursor != nil
            context.sections["recent_conversation"] = recent
            context.metadata["recent_conversation_from_turn"] = start
            context.metadata["history_revision"] = historyRevision(archive)
        }
        let allowed = tools.systemCalendar.conversationAllowed && tools.systemCalendar.systemAuthorized
        context.metadata["calendar_allowed"] = allowed
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        context.metadata["calendar_range"] = ["start": start.ISO8601Format(), "end_exclusive": end.ISO8601Format()]
        if allowed {
            do {
                context.sections["calendar"] = try tools.systemCalendar.events(start: start, end: end, calendarID: nil)
                    .map { event in
                        context.boundaries += [event.fields.start, event.fields.end].filter { $0 > now }
                        var row = try json(event)
                        row["phase"] = now < event.fields.start ? "upcoming" : now < event.fields.end ? "ongoing" : "ended"
                        return row
                    }.sorted {
                        BriefContext.fingerprint($0) < BriefContext.fingerprint($1)
                    }
            } catch { unavailable["calendar"] = "日历读取失败，不能断言没有日历安排" }
        } else {
            unavailable["calendar"] = "未获模型读取许可或系统权限；首页显示权限不等于模型读取许可，不读取事件，也不主动申请权限"
        }
        context.metadata["unavailable"] = unavailable
        return context
    }

    static func historyRevision(_ archive: ConversationArchive) -> String {
        BriefContext.fingerprint(["error": archive.readError ?? "", "turns": archive.turns.map {
            ["id": $0.id.uuidString, "question": $0.question, "answer": $0.answer, "receipts": $0.receipts,
             "date": $0.date.ISO8601Format(), "source": archive.sources[$0.id]?.key ?? ""] as [String: Any]
        }])
    }

    private static func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] ?? [:]
    }
}
