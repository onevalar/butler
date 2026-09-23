import Foundation
import Observation

enum InventoryInputState: Equatable, Sendable {
    case idle, planning, clarifying, reviewing, executing, completed, failed
}

@MainActor @Observable
final class InventoryInputCoordinator {
    private let provider: any InventoryPlanProvider
    private let lookup: CatalogProductLookup
    private let repository: InventoryRepository
    private var session: InventoryPlanSession?

    private(set) var state: InventoryInputState = .idle
    private(set) var questions: [InventoryPlanningQuestion] = []
    private(set) var reviewPlan: InventoryOperationPlan?
    private(set) var confirmationRequirements: [InventoryConfirmationRequirement] = []
    private(set) var errorMessage: String?
    private(set) var executionResult: InventoryExecutionResult?
    private(set) var productDisplays: [UUID: CatalogProductCandidate] = [:]
    private(set) var existingProductIDs: Set<UUID> = []
    /// Re-purchases linked to their only same-name product without asking; the review can undo it.
    /// Keyed by the existing product ID, valued by the createProduct operations it replaced.
    private(set) var autoLinked: [UUID: [UUID]] = [:]

    init(provider: any InventoryPlanProvider, lookup: CatalogProductLookup, repository: InventoryRepository) {
        self.provider = provider; self.lookup = lookup; self.repository = repository
    }

    /// Nothing to clean up; keep deinit off the MainActor executor to avoid a Swift 6.2 runtime crash
    /// (swift_task_deinitOnExecutor frees an unallocated TaskLocal scope when released on the main thread).
    nonisolated deinit {}

    func submit(text: String, locale: Locale = .current, referenceDate: Date = Date(), timeZone: TimeZone = .current) async {
        guard state != .planning && state != .executing else { return }
        state = .planning; errorMessage = nil; questions = []; reviewPlan = nil
        confirmationRequirements = []; executionResult = nil; productDisplays = [:]; existingProductIDs = []
        autoLinked = [:]; session = nil
        do {
            let input = InventoryPlanningInput(text: text, locale: locale, referenceDate: referenceDate,
                                               timeZone: timeZone, inputID: UUID(), planID: UUID())
            let base = try await provider.plan(for: input) // exactly once per submit
            try validateM2Plan(base, input: input)
            session = InventoryPlanSession(basePlan: base, referenceDate: referenceDate)
            questions = base.unresolvedFields.filter(\.isRequired).map { .field($0) }
            for operation in base.operations {
                guard case .createProduct(let product) = operation.operation else { continue }
                productDisplays[product.productID] = .init(
                    id: product.productID, canonicalName: product.canonicalName,
                    brand: product.brand, defaultUnit: product.defaultUnit
                )
                let candidates = try lookup.exactMatches(for: product.canonicalName)
                if candidates.count == 1, let existing = candidates.first {
                    // Buying the same thing again is the common case: don't ask, show it in the review.
                    session?.choose(forCreateOperation: operation.operationID, .existing(productID: existing.id))
                    productDisplays[existing.id] = existing
                    existingProductIDs.insert(existing.id)
                    autoLinked[existing.id, default: []].append(operation.operationID)
                } else if candidates.count > 1 {
                    questions.append(.productChoice(operationID: operation.operationID,
                                                    proposedProductID: product.productID, candidates: candidates))
                }
            }
            refresh()
        } catch { fail(error) }
    }

    func answerStorage(_ field: UnresolvedInventoryField, choice: InventoryStorageChoice) {
        guard state == .clarifying,
              questions.contains(where: { if case .field(let value) = $0 { return value == field }; return false }) else { return }
        session?.answer(field, with: .storageLocation(choice))
        questions.removeAll { if case .field(let value) = $0 { return value == field }; return false }
        refresh()
    }

    /// "先跳过": record the literal "冰箱" the user said; Home asks for the compartment later.
    func postponeStorage(_ field: UnresolvedInventoryField) {
        guard state == .clarifying,
              questions.contains(where: { if case .field(let value) = $0 { return value == field }; return false }) else { return }
        session?.answer(field, with: .postponedStorage(statedLocation: StorageLocation.ambiguousFridge))
        questions.removeAll { if case .field(let value) = $0 { return value == field }; return false }
        refresh()
    }

    /// Review-time undo of an automatic "same product" link: record it as a new, separate product.
    func keepSeparate(fromExisting productID: UUID) {
        guard state == .reviewing, let operationIDs = autoLinked.removeValue(forKey: productID) else { return }
        for operationID in operationIDs { session?.choose(forCreateOperation: operationID, .createSeparate) }
        existingProductIDs.remove(productID)
        refresh()
    }

    func reset() {
        guard state != .planning && state != .executing else { return }
        state = .idle; errorMessage = nil; questions = []; reviewPlan = nil
        confirmationRequirements = []; executionResult = nil; productDisplays = [:]; existingProductIDs = []
        autoLinked = [:]; session = nil
    }

    func chooseProduct(createOperationID: UUID, choice: InventoryProductChoice) {
        guard state == .clarifying,
              let pending = questions.first(where: {
                  if case .productChoice(let id, _, _) = $0 { return id == createOperationID }; return false
              }),
              case .productChoice(_, let proposedProductID, let candidates) = pending else { return }
        if case .existing(let productID) = choice {
            guard let selected = candidates.first(where: { $0.id == productID }) else { return }
            productDisplays[productID] = selected
            existingProductIDs.insert(productID)
        } else {
            guard productDisplays[proposedProductID] != nil else { return }
        }
        session?.choose(forCreateOperation: createOperationID, choice)
        questions.removeAll {
            if case .productChoice(let id, _, _) = $0 { return id == createOperationID }; return false
        }
        refresh()
    }

    /// Explicit review boundary: no state automatically executes.
    func confirmAndExecute() {
        guard state == .reviewing, let plan = reviewPlan else { return }
        let currentDecision = InventoryPolicy.evaluate(plan)
        let requirements: [InventoryConfirmationRequirement]
        switch currentDecision {
        case .execute: requirements = []
        case .requiresConfirmation(let visible):
            guard sameRequirements(visible, confirmationRequirements) else { refresh(); return }
            requirements = visible
        case .requiresClarification, .reject: refresh(); return
        }
        state = .executing
        do {
            let receipts = requirements.map { InventoryConfirmationAuthority.issue(for: $0) }
            executionResult = try repository.execute(plan, trustedConfirmations: receipts, actor: .user)
            state = .completed
        } catch { fail(error) }
    }

    private func refresh() {
        guard let revision = session?.materialize() else { return }
        reviewPlan = revision.plan
        guard questions.isEmpty else { state = .clarifying; return }
        let unresolvedProduct = revision.plan.operations.contains { planned in
            guard case .addLot(let lot) = planned.operation else { return false }
            return productDisplays[lot.productID] == nil
        }
        guard !unresolvedProduct else {
            failMessage("有批次无法关联到可审核的产品身份。")
            return
        }
        switch InventoryPolicy.evaluate(revision.plan) {
        case .execute: confirmationRequirements = []; state = .reviewing
        case .requiresConfirmation(let requirements): confirmationRequirements = requirements; state = .reviewing
        case .requiresClarification(let fields): questions = fields.map { .field($0) }; state = .clarifying
        case .reject(let violations): failMessage(violations.map(\.message).joined(separator: "\n"))
        }
    }

    private func sameRequirements(_ lhs: [InventoryConfirmationRequirement], _ rhs: [InventoryConfirmationRequirement]) -> Bool {
        func keys(_ values: [InventoryConfirmationRequirement]) -> Set<String> {
            Set(values.map { "\($0.planID)|\($0.operationID)|\($0.entityID)|\($0.fieldKey.rawValue)|\($0.proposedValueIdentity)|\($0.expectedRevision.map(String.init) ?? "nil")" })
        }
        return keys(lhs) == keys(rhs)
    }

    private func validateM2Plan(_ plan: InventoryOperationPlan, input: InventoryPlanningInput) throws {
        guard plan.planID == input.planID, plan.inputID == input.inputID else {
            throw InventoryPlanningError.invalidProviderPlan("请求标识不匹配")
        }
        var products: [UUID: UUID] = [:]
        var lots: [UUID: (operationID: UUID, productID: UUID)] = [:]
        for planned in plan.operations {
            switch planned.operation {
            case .createProduct(let product):
                guard products.updateValue(planned.operationID, forKey: product.productID) == nil else {
                    throw InventoryPlanningError.invalidProviderPlan("产品标识重复")
                }
            case .addLot(let lot):
                guard lots.updateValue((planned.operationID, lot.productID), forKey: lot.lotID) == nil else {
                    throw InventoryPlanningError.invalidProviderPlan("批次标识重复")
                }
            default:
                throw InventoryPlanningError.invalidProviderPlan("M2 输入仅允许创建产品和批次")
            }
        }
        let operationIDs = plan.operations.map(\.operationID)
        guard Set(operationIDs).count == operationIDs.count else {
            throw InventoryPlanningError.invalidProviderPlan("操作标识重复")
        }
        guard !products.isEmpty, !lots.isEmpty,
              Set(lots.values.map { $0.productID }) == Set(products.keys) else {
            throw InventoryPlanningError.invalidProviderPlan("产品与批次必须完整一一关联")
        }
        let unresolvedIdentities = plan.unresolvedFields.map {
            "\($0.operationID)|\($0.entityID)|\($0.fieldKey.rawValue)"
        }
        guard Set(unresolvedIdentities).count == unresolvedIdentities.count else {
            throw InventoryPlanningError.invalidProviderPlan("追问字段重复")
        }
        for field in plan.unresolvedFields {
            guard field.fieldKey == .storageLocation,
                  let lot = lots[field.entityID], lot.operationID == field.operationID else {
                throw InventoryPlanningError.invalidProviderPlan("追问字段未指向对应批次")
            }
        }
    }
    private func fail(_ error: Error) { failMessage((error as? LocalizedError)?.errorDescription ?? String(describing: error)) }
    private func failMessage(_ message: String) { errorMessage = message; state = .failed }
}
