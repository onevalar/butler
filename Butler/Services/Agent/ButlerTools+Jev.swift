import Foundation
import Observation
import SwiftData

extension ButlerTools {
    // MARK: - Judgment layer (Jev between the model and the data)

    static let targetQuestion = "用户这句话说的是这一件物品吗？"
    static let relevanceQuestion = "这件物品与用户这句话提到或询问的东西有关吗？"
    static let meaningQuestion = "用户这句话的意思是这个结果吗？"
    static let statedDateQuestion = "这个日期是用户在对话里明确说出的吗？"
    static let newPurchaseQuestion = "对于家里已有的这件物品，用户这句话是在说又新买了一份（而不是在说这件本身，或纠正它的信息）吗？"

    struct Review {
        var checked = false
        var concern: String?
        var check: JevCheck? { checked ? .passed : nil }
    }


    private var jevRequest: String {
        guard let previous, !previous.isEmpty else { return request }
        return "上一句：\(previous)\n这一句：\(request)"
    }

    /// nil when Jev is off, unconfigured or failed; callers proceed exactly as without Jev.
    func ask(_ questions: [JevClient.Question]) async -> [String: Double]? {
        guard jev.isAvailable else {
            jevJudgments.invalidateConfiguration()
            jevFailure = nil
            return nil
        }
        guard !request.isEmpty, !questions.isEmpty else { return nil }
        let generation = jevJudgments.generation
        let configuration = jev.reuseToken
        let context = jevRequest
        do {
            let answers = try await jevJudgments.judge(request: context, questions: questions, using: jev)
            guard generation == jevJudgments.generation, configuration == jev.reuseToken,
                  context == jevRequest, jev.isAvailable else { return nil }
            jevFailure = nil
            return answers
        } catch {
            guard generation == jevJudgments.generation, configuration == jev.reuseToken,
                  context == jevRequest, jev.isAvailable else { return nil }
            jevFailure = error.localizedDescription
            return nil
        }
    }

    /// Checks that `lot` is what the owner means (against same-name siblings) plus any extra questions.
    func reviewTarget(_ lot: LotFacts, extra: [JevClient.Question] = [],
                              interpret: ([String: Double]) -> String? = { _ in nil }) async -> Review {
        let siblings = (try? self.siblings(of: lot)) ?? []
        let questions = ([lot] + siblings).map {
            JevClient.Question(id: "t." + $0.id.uuidString, question: Self.targetQuestion, candidate: Self.jevText($0))
        } + extra
        guard let answers = await ask(questions) else { return Review() }
        var review = Review(checked: true)
        let target = answers["t." + lot.id.uuidString] ?? 1
        let best = siblings.map { ($0, answers["t." + $0.id.uuidString] ?? 0) }.max { $0.1 < $1.1 }
        if let (other, p) = best, target < 0.5, p > target + 0.2 {
            review.concern = "用户更可能指的是另一件：\(Self.jevText(other))（lot_id \(other.id.uuidString)）"
        } else if target < 0.3 {
            review.concern = "用户可能不是在说这件（\(Self.jevText(lot))）"
        } else {
            review.concern = interpret(answers)
        }
        return review
    }

    /// For each new item that already exists at home: is it really a new purchase? Is a package date stated?
    func reviewAdd(_ items: [InventoryActions.NewItem]) async -> Review {
        var questions: [JevClient.Question] = []
        var existing: [Int: [LotFacts]] = [:]
        for (index, item) in items.enumerated() {
            let lots = ((try? activeLots()) ?? []).filter { $0.name == item.name || $0.productID == item.existingProductID }
            existing[index] = Array(lots.prefix(4))
            questions += lots.prefix(4).map {
                .init(id: "n.\(index).\($0.id.uuidString)", question: Self.newPurchaseQuestion,
                      candidate: Self.jevText($0) + "；用户这次提到：\(item.name) ×\(item.quantity) \(item.unit)")
            }
            if let date = item.packageExpiry, !hasPhotos {
                questions.append(.init(id: "d.\(index)", question: Self.statedDateQuestion,
                                       candidate: "\(item.name) 包装有效期 \(date.isoDay)"))
            }
        }
        guard !questions.isEmpty else { return Review() }
        guard let answers = await ask(questions) else { return Review() }
        var review = Review(checked: true)
        for (index, item) in items.enumerated() {
            let lots = existing[index] ?? []
            let newP = lots.map { answers["n.\(index).\($0.id.uuidString)"] ?? 1 }
            if let first = lots.first, let highest = newP.max(), highest < 0.4 {
                review.concern = "用户可能是在说家里已有的 \(Self.jevText(first))（lot_id \(first.id.uuidString)），不是新买；如果是纠正，请修改原记录"
                break
            }
            if let stated = answers["d.\(index)"], stated < 0.3 {
                review.concern = "\(item.name) 的包装有效期看起来不是用户明确说出的，不要推测，改为 null"
                break
            }
        }
        return review
    }

    /// nil = go ahead. Otherwise the tool output telling the model what Jev objected to.
    func gate(_ signature: String, _ review: Review) -> String? {
        guard let concern = review.concern else { return nil }
        if raisedConcerns.contains(signature) { insistedConcern = concern; return nil }
        raisedConcerns.insert(signature)
        return (try? encode(["status": "needs_review", "saved": false, "jev_concern": concern,
                             "hint": "请按这个判断修正后重新提出；拿不准就直接问用户，不要猜。如果你仍确定原提议正确，可以原样再提一次，卡片上会显示这条提醒让用户决定。"]
                            as [String: Any])) ?? #"{"status":"needs_review","saved":false}"#
    }
}
