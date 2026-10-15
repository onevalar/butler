import Foundation
import Observation
import SwiftData

extension ButlerTools {
    /// Read-only, bounded data for this turn. Bypasses judgment, proposals and cached results.
    /// A failed store is reported explicitly while the other selected store can still succeed.
    func prefetch(inventory: Bool, notes: Bool) async throws -> [PrefetchedToolResult] {
        try Task.checkCancellation()
        var results: [PrefetchedToolResult] = []
        let selected = [("search_inventory", inventory), ("search_notes", notes)]
        for (name, enabled) in selected where enabled {
            try Task.checkCancellation()
            let isInventory = name == "search_inventory"
            let arguments = isInventory ? #"{"query":"","include_finished":false}"# : #"{"query":""}"#
            let call = LocalToolCall(id: "prefetch_" + UUID().uuidString, name: name, arguments: arguments)
            let source = isInventory ? "local_inventory" : "local_notes"
            let scope = isInventory ? Self.inventoryScope(query: "", includeFinished: false) : Self.notesScope
            let output: String
            do {
                let value = isInventory
                    ? try await searchInventory("", includeFinished: false, limit: 40, byteBudget: 12_000, useJev: false)
                    : try prefetchedNotes()
                try Task.checkCancellation()
                output = try encode(value)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                output = try encode([
                    "source": source, "queried_at": Self.queryTimestamp, "scope": scope,
                    "error": error.localizedDescription, "count": NSNull(), "returned_count": 0,
                    "complete": false, "truncated": false,
                ] as [String: Any])
            }
            results.append(PrefetchedToolResult(call: call, output: output))
        }
        try Task.checkCancellation()
        return results
    }

    func allLots() throws -> [(InventoryLot, CatalogProduct?)] {
        let context = ModelContext(container)
        let products = Dictionary(try context.fetch(FetchDescriptor<CatalogProduct>()).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        // A present hidden from this person is neither listed nor told to the model.
        let household = self.household
        return try context.fetch(FetchDescriptor<InventoryLot>()).filter { household.isVisible($0.productID) }
            .map { ($0, products[$0.productID]) }
    }

    /// Everything at home right now.
    func activeFacts() throws -> [LotFacts] { try activeLots() }

    func activeLots() throws -> [LotFacts] {
        try allLots().filter { $0.0.state == .active }.map { LotFacts(lot: $0.0, product: $0.1) }
    }

    func siblings(of lot: LotFacts) throws -> [LotFacts] {
        Array(try activeLots().filter { $0.id != lot.id && ($0.productID == lot.productID || $0.name == lot.name) }.prefix(6))
    }

    /// One line Jev can read about a lot.
    static func jevText(_ lot: LotFacts) -> String {
        var parts = [lot.name + (lot.brand.map { "（\($0)）" } ?? ""), "\(lot.quantity) \(lot.unit)"]
        if let storage = lot.storageLocation { parts.append("放在\(storage)") }
        if let profile = lot.profile { parts.append(profile.searchText) }
        parts.append("\(lot.startedAt.monthDay)买的")
        if let date = lot.governingDate {
            parts.append((lot.governingDateKind == .plannedUseBy ? "计划 " : "有效期 ") + date.monthDay)
        }
        return parts.joined(separator: "，")
    }

    func activeLot(_ raw: String) throws -> LotFacts {
        guard let id = UUID(uuidString: raw),
              let (lot, product) = try allLots().first(where: { $0.0.id == id }) else {
            throw ToolError("找不到这件物品，请先用 search_inventory 查到它的 lot_id")
        }
        guard lot.state == .active else { throw ToolError("这件物品已经处理掉了") }
        return LotFacts(lot: lot, product: product)
    }

    /// Re-reads a lot right before writing. A change made in between (by the owner or an earlier
    /// change in this batch) is fine as long as it's the same lot and still active.
    func fresh(_ lot: LotFacts) throws -> LotFacts {
        try activeLot(lot.id.uuidString)
    }

    func searchInventory(_ query: String, includeFinished: Bool, limit: Int = 80,
                                 byteBudget: Int? = nil, useJev: Bool = true) async throws -> [String: Any] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lots = try allLots()
        // "牛奶 鸡蛋" or "牛奶、鸡蛋" matches either word.
        let words = query.split(whereSeparator: { " ,，、;；".contains($0) }).map(String.init)
        func matches(_ lot: InventoryLot, _ product: CatalogProduct?) -> Bool {
            guard !words.isEmpty else { return true }
            let haystack = [product?.canonicalName, product?.brand, lot.storageLocation, lot.itemProfile?.searchText, ItemProfile.inferred(name: product?.canonicalName ?? "", legacyCategory: product?.categoryRawValue).category.title].compactMap { $0 }.joined(separator: " ")
            return words.contains { word in
                haystack.localizedStandardContains(word)
                    || (product?.canonicalName).map { !$0.isEmpty && word.localizedStandardContains($0) } == true
            }
        }
        let allActive = lots.filter { $0.0.state == .active }.map { LotFacts(lot: $0.0, product: $0.1) }
            .sorted { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        var active = lots.filter { $0.0.state == .active && matches($0.0, $0.1) }
            .map { LotFacts(lot: $0.0, product: $0.1) }
            .sorted { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        var items = active.map(Self.describe)
        var semanticExcludedCount = 0
        var result: [String: Any] = [
            "today": Date.now.isoDay, "queried_at": Self.queryTimestamp, "source": "local_inventory",
            "scope": Self.inventoryScope(query: query, includeFinished: includeFinished),
            "count_unit": "inventory_lots", "quantity_semantics": "每个批次的quantity是该批次的剩余数量，单位见unit；不同单位不可直接相加",
        ]

        // Jev between the data and the model: rank what the words matched, or find what they missed.
        // An overview ("" query) has nothing to disambiguate and is left as is.
        if useJev && !words.isEmpty {
            let pool = active.count >= 2 && active.count <= 30 ? active
                : active.isEmpty && allActive.count <= 60 ? allActive : []
            let answers = await ask(pool.map {
                .init(id: $0.id.uuidString, question: Self.relevanceQuestion, candidate: Self.jevText($0))
            })
            if let answers {
                let keywordMissed = active.isEmpty
                let scored = pool.map { ($0, answers[$0.id.uuidString] ?? 0) }
                let kept = active.isEmpty ? scored.filter { $0.1 >= 0.5 } : scored // never drop what the words matched
                active = kept.sorted { $0.1 > $1.1 }.map(\.0)
                items = kept.sorted { $0.1 > $1.1 }.map { lot, p in
                    var item = Self.describe(lot)
                    item["relevance"] = (p * 100).rounded() / 100
                    return item
                }
                result["judged_by"] = "jev"
                if keywordMissed {
                    semanticExcludedCount = pool.count - kept.count
                    result["semantically_filtered"] = true
                    result["semantic_excluded_count"] = semanticExcludedCount
                    result["semantic_candidate_count"] = pool.count
                    result["hint"] = "Jev相关性筛选可能漏项，不能据此断言没有；可查询全部或更换关键词"
                    result["found_by"] = "jev（关键词没有直接命中）"
                    result["scope"] = Self.inventoryScope(query: query, includeFinished: includeFinished,
                                                          matchMethod: "jev_candidate_pool")
                }
            } else if let jevFailure, !pool.isEmpty {
                result["jev"] = "暂时不可用（\(jevFailure)），以下是未经判断的原始结果"
            }
        }
        items = try Self.boundedRecords(items, limit: limit, byteBudget: byteBudget)
        let activeComplete = items.count == active.count && semanticExcludedCount == 0
        result["count"] = active.count
        result["returned_count"] = items.count
        result["complete"] = activeComplete
        result["truncated"] = items.count < active.count
        result["active_complete"] = activeComplete
        result["active_truncated"] = items.count < active.count
        result["items"] = items
        // A specific search is a real reference. Broad overviews/prefetch must not attach
        // every household item to a conversation that may never discuss any of them.
        let referencedItems = words.isEmpty ? items.filter {
            guard let name = $0["name"] as? String, !name.isEmpty else { return false }
            return request.localizedStandardContains(name)
        } : items
        relatedScopes.formUnion(referencedItems.compactMap { ($0["lot_id"] as? String).flatMap(UUID.init).map(ChatScope.lot) })
        if includeFinished {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            let finished = lots.filter { $0.0.state != .active && $0.0.updatedAt >= cutoff && matches($0.0, $0.1) }
                .sorted { $0.0.updatedAt > $1.0.updatedAt }
            let returned = finished.prefix(30)
                .map { lot, product in
                    ["lot_id": lot.id.uuidString, "name": product?.canonicalName ?? "未命名",
                     "state": lot.state.rawValue, "when": lot.updatedAt.isoDay] as [String: Any]
                }
            result["finished"] = returned
            if !words.isEmpty {
                relatedScopes.formUnion(returned.compactMap { ($0["lot_id"] as? String).flatMap(UUID.init).map(ChatScope.lot) })
            }
            result["finished_count"] = finished.count
            result["finished_returned_count"] = returned.count
            result["finished_complete"] = finished.count == returned.count
            result["finished_truncated"] = finished.count > returned.count
            result["complete"] = activeComplete && finished.count == returned.count
            result["truncated"] = items.count < active.count || finished.count > returned.count
        }
        return result
    }

    private static var queryTimestamp: String { ISO8601DateFormatter().string(from: .now) }

    private static func inventoryScope(query: String, includeFinished: Bool, matchMethod: String? = nil) -> [String: Any] {
        ["query": query, "active_states": ["active"], "include_finished": includeFinished,
         "match_method": matchMethod ?? (query.isEmpty ? "all_active" : "keyword"),
         "complete_means": "all_matching_records_returned_within_scope",
         "finished_window_days": includeFinished ? 30 : 0,
         "finished_date_field": "updated_at", "conversation_history_included": false,
         "older_finished_included": false]
    }

    private static var notesScope: [String: Any] {
        ["query": "", "records": "current_saved_notes", "conversation_history_included": false,
         "inventory_included": false, "previous_note_revisions_included": false]
    }

    private func prefetchedNotes() throws -> [String: Any] {
        let records = notes.records
        let all = records.map { note -> [String: Any] in
            var record: [String: Any] = ["id": note.id.uuidString, "title": note.title,
                                          "text": note.text, "revision": note.revision]
            if let quantity = note.quantity { record["quantity"] = quantity }
            return record
        }
        let returned = try Self.boundedRecords(all, limit: 20, byteBudget: 8_000)
        return ["source": "local_notes", "queried_at": Self.queryTimestamp, "scope": Self.notesScope,
                "count": records.count, "count_unit": "notes", "returned_count": returned.count,
                "complete": returned.count == records.count, "truncated": returned.count < records.count,
                "notes": returned]
    }

    /// Measures the exact JSON array's UTF-8 bytes, including brackets and commas. A record is
    /// included whole or skipped; a large record must not hide smaller records after it.
    private static func boundedRecords(_ records: [[String: Any]], limit: Int, byteBudget: Int?) throws -> [[String: Any]] {
        guard let byteBudget else { return Array(records.prefix(limit)) }
        var returned: [[String: Any]] = []
        var bytes = 2 // []
        for record in records {
            guard returned.count < limit else { break }
            let recordBytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).count
            let addedBytes = recordBytes + (returned.isEmpty ? 0 : 1)
            guard bytes + addedBytes <= byteBudget else { continue }
            returned.append(record)
            bytes += addedBytes
        }
        return returned
    }

    private static func describe(_ lot: LotFacts) -> [String: Any] {
        var item: [String: Any] = ["lot_id": lot.id.uuidString, "name": lot.name, "quantity": lot.quantity,
                                   "unit": lot.unit, "time_left": lot.timeLeftLabel]
        if let brand = lot.brand { item["brand"] = brand }
        if let storage = lot.storageLocation { item["storage"] = storage }
        if let days = lot.daysLeft { item["days_left"] = days }
        if let kind = lot.governingDateKind { item["governing_date_kind"] = kind.rawValue }
        if let date = lot.governingDate { item["governing_date"] = date.isoDay }
        if lot.isMedicine { item["is_medicine"] = true }
        item["revision"] = lot.revision
        item["category"] = lot.category.rawValue
        item["category_label"] = lot.category.title
        if let profile = lot.profile {
            item["attributes"] = profile.attributes; item["tags"] = profile.tags
            item["availability"] = profile.availability; item["has_photo"] = profile.photo != nil
        }
        item["track"] = lot.quantityOnly ? "quantity" : "expiry"
        item["bought"] = lot.startedAt.isoDay
        return item
    }
}
