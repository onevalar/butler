#if DEBUG
import Foundation

/// Small, deterministic Chinese fixture parser. It intentionally declines broad NLP guesses.
struct LocalInventoryPlanProvider: InventoryPlanProvider {
    private let maximumClauses = 20
    private let units = "瓶|包|盒|袋|罐|支|条|片|只|块|桶|个"

    private struct Draft {
        let productID: UUID
        let lotID: UUID
        let createOperationID: UUID
        let addOperationID: UUID
        let quantity: Int
        let countText: String
        let unit: String
        let name: String
        var plannedUseByDate: Date?
        var packageExpiryDate: Date?
        var lotEvidence: [ProposedFieldEvidence]
        var needsColdStorageClarification: Bool
    }

    func plan(for input: InventoryPlanningInput) async throws -> InventoryOperationPlan {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InventoryPlanningError.emptyInput }
        let clauses = splitClauses(text)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard clauses.count <= maximumClauses else { throw InventoryPlanningError.tooManyClauses(maximum: maximumClauses) }

        var drafts: [Draft] = []
        for clause in clauses {
            guard let parsed = parseHead(clause) else { continue }
            var plannedUse: Date?
            var packageExpiry: Date?
            var lotEvidence: [ProposedFieldEvidence] = [
                .init(fieldKey: .quantity, source: .heuristicParser, confidence: 1, rawText: parsed.countText),
                .init(fieldKey: .unit, source: .heuristicParser, confidence: 1, rawText: parsed.unit)
            ]
            if clause.contains("一个月内") && (clause.contains("吃掉") || clause.contains("用掉") || clause.contains("喝掉")) {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
                plannedUse = calendar.date(byAdding: .month, value: 1, to: input.referenceDate)
                lotEvidence.append(.init(fieldKey: .plannedUseByDate, source: .systemEstimate, confidence: 1, rawText: "一个月内"))
            }
            if plannedUse == nil && parsed.name.contains("方便面") {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
                plannedUse = calendar.date(byAdding: .month, value: 3, to: input.referenceDate)
                lotEvidence.append(.init(
                    fieldKey: .plannedUseByDate, source: .systemEstimate, confidence: 0.7,
                    rawText: "本地默认：三个月内用完"
                ))
            }
            if clause.contains("过期") {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
                let days = clause.contains("后天过期") ? 2 : (clause.contains("明天过期") ? 1 : 0)
                if days > 0 {
                    packageExpiry = calendar.date(byAdding: .day, value: days, to: input.referenceDate)
                    lotEvidence.append(.init(fieldKey: .packageExpiryDate, source: .heuristicParser,
                                             confidence: 1, rawText: days == 1 ? "明天过期" : "后天过期"))
                }
                // Other expiry expressions remain absent rather than becoming a fabricated package date.
            }
            drafts.append(.init(
                productID: UUID(), lotID: UUID(), createOperationID: UUID(), addOperationID: UUID(),
                quantity: parsed.quantity, countText: parsed.countText, unit: parsed.unit, name: parsed.name,
                plannedUseByDate: plannedUse, packageExpiryDate: packageExpiry, lotEvidence: lotEvidence,
                needsColdStorageClarification: clause.contains("冰箱")
            ))
        }

        // A later clause may add detail without repeating a quantity, e.g. “冰激凌先放冰箱了”。
        for clause in clauses where parseHead(clause) == nil && clause.contains("冰箱") {
            for index in drafts.indices where clause.contains(drafts[index].name) {
                drafts[index].needsColdStorageClarification = true
            }
        }

        guard !drafts.isEmpty else { throw InventoryPlanningError.noInventoryItems }
        var operations: [PlannedInventoryOperation] = []
        var unresolved: [UnresolvedInventoryField] = []
        for draft in drafts {
            let productEvidence = [ProposedFieldEvidence(
                fieldKey: .canonicalName, source: .heuristicParser, confidence: 1, rawText: draft.name
            )]
            operations.append(.init(operationID: draft.createOperationID, operation: .createProduct(.init(
                productID: draft.productID, canonicalName: draft.name, brand: nil, categoryRawValue: nil,
                defaultUnit: nil, evidence: productEvidence))))
            operations.append(.init(operationID: draft.addOperationID, operation: .addLot(.init(
                lotID: draft.lotID, productID: draft.productID, quantity: draft.quantity, unit: draft.unit,
                purchasedAt: nil, packageExpiryDate: draft.packageExpiryDate, estimatedExpiryDate: nil,
                plannedUseByDate: draft.plannedUseByDate, storageLocation: nil, evidence: draft.lotEvidence))))
            if draft.needsColdStorageClarification {
                unresolved.append(.init(operationID: draft.addOperationID, entityID: draft.lotID,
                                        fieldKey: .storageLocation, reason: "storage.coldAmbiguous", isRequired: true))
            }
        }
        return .init(schemaVersion: 1, planID: input.planID, inputID: input.inputID,
                     operations: operations, unresolvedFields: unresolved)
    }

    private func splitClauses(_ text: String) -> [String] {
        let conjunctionPattern = "和(?=[0-9一二两三四五六七八九十]+(?:\(units)))"
        let range = NSRange(text.startIndex..., in: text)
        let separated = (try? NSRegularExpression(pattern: conjunctionPattern))?
            .stringByReplacingMatches(in: text, range: range, withTemplate: "、") ?? text
        return separated.components(separatedBy: CharacterSet(charactersIn: "、，,。；;"))
    }

    private func parseHead(_ clause: String) -> (quantity: Int, countText: String, unit: String, name: String)? {
        let pattern = "([0-9一二两三四五六七八九十]+)(\(units))(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: clause, range: NSRange(clause.startIndex..., in: clause)),
              let countRange = Range(match.range(at: 1), in: clause),
              let unitRange = Range(match.range(at: 2), in: clause),
              let tailRange = Range(match.range(at: 3), in: clause) else { return nil }
        let countText = String(clause[countRange]), unit = String(clause[unitRange])
        guard let quantity = chineseInteger(countText), quantity > 0 else { return nil }
        var name = String(clause[tailRange])
        let detailMarkers = ["一个月内", "明天过期", "后天过期", "先放冰箱", "放冰箱"]
        if let markerIndex = detailMarkers.compactMap({ name.range(of: $0)?.lowerBound }).min() {
            name = String(name[..<markerIndex])
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (quantity, countText, unit, name)
    }

    private func chineseInteger(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        if value == "十" { return 10 }
        if value.hasPrefix("十"), let last = value.last, let d = digits[last] { return 10 + d }
        if value.contains("十"), let first = value.first, let d = digits[first] {
            return d * 10 + (value.last.flatMap { digits[$0] } ?? 0)
        }
        return value.count == 1 ? value.first.flatMap { digits[$0] } : nil
    }
}
#endif
