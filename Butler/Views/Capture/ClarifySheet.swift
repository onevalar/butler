import SwiftUI

/// One question at a time, rising over the capture screen. Each option states its consequence.
struct ClarifySheet: View {
    let coordinator: InventoryInputCoordinator
    let question: InventoryPlanningQuestion

    @State private var storageChoice: InventoryStorageChoice = .frozen
    @State private var sameProduct = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Theme.dashed).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 22)
            HStack(alignment: .top, spacing: 16) {
                SealView(glyph: glyph, style: .solid, size: 60, tilt: -6)
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(coordinator.questions.count > 1 ? "还有 \(coordinator.questions.count) 个问题" : "只问一个问题",
                            color: Theme.muted)
                    Text(title)
                        .font(Theme.display(24))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(detail)
                .font(Theme.body(14))
                .foregroundStyle(Theme.muted)
                .lineSpacing(6)
                .padding(.top, 12)
                .padding(.bottom, 22)
            choices
            VStack(spacing: 14) {
                Button("好，继续", action: submit)
                    .buttonStyle(PillButtonStyle(kind: .capsule))
                if case .field(let field) = question {
                    Button("先跳过，回头在首页告诉我") { coordinator.postponeStorage(field) }
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30)
                .fill(Theme.ground)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: Content per question

    private var subjectName: String {
        switch question {
        case .field(let field):
            guard let plan = coordinator.reviewPlan else { return "它" }
            for planned in plan.operations {
                if case .addLot(let lot) = planned.operation, lot.lotID == field.entityID {
                    return coordinator.productDisplays[lot.productID]?.canonicalName ?? "它"
                }
            }
            return "它"
        case .productChoice(_, let proposedID, _):
            return coordinator.productDisplays[proposedID]?.canonicalName ?? "它"
        }
    }

    private var glyph: Character {
        LotGlyph.glyph(for: subjectName, isMedicine: LotGlyph.isMedicine(name: subjectName, category: nil))
    }

    private var title: String {
        switch question {
        case .field: "\(subjectName)放在哪一层？"
        case .productChoice: "家里已经有\(subjectName)了，是同一种吗？"
        }
    }

    private var detail: String {
        switch question {
        case .field:
            return "你说“放冰箱”，但冷冻和冷藏能放的时间差很多。"
        case .productChoice(_, _, let candidates):
            if let brand = candidates.first?.brand { return "之前记的是 \(brand) 的。同一种我会放在一起，方便算你多久买一次。" }
            return "同一种我会放在一起，方便算你多久买一次。"
        }
    }

    @ViewBuilder
    private var choices: some View {
        switch question {
        case .field:
            HStack(spacing: 10) {
                ChoiceTile(title: "冷冻层", number: "60", caption: "天内吃完", selected: storageChoice == .frozen, warn: false) {
                    storageChoice = .frozen
                }
                ChoiceTile(title: "冷藏层", number: "1", caption: "天，会化", selected: storageChoice == .refrigerated, warn: true) {
                    storageChoice = .refrigerated
                }
            }
        case .productChoice:
            HStack(spacing: 10) {
                ChoiceTile(title: "同一种", number: nil, caption: "合在一起记", selected: sameProduct, warn: false) { sameProduct = true }
                ChoiceTile(title: "新的一种", number: nil, caption: "分开记", selected: !sameProduct, warn: false) { sameProduct = false }
            }
        }
    }

    private func submit() {
        switch question {
        case .field(let field):
            coordinator.answerStorage(field, choice: storageChoice)
        case .productChoice(let operationID, _, let candidates):
            if sameProduct, let existing = candidates.first {
                coordinator.chooseProduct(createOperationID: operationID, choice: .existing(productID: existing.id))
            } else {
                coordinator.chooseProduct(createOperationID: operationID, choice: .createSeparate)
            }
        }
    }
}

private struct ChoiceTile: View {
    let title: String
    let number: String?
    let caption: String
    let selected: Bool
    let warn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title)
                        .font(Theme.display(18))
                        .foregroundStyle(selected ? .white : Theme.ink)
                    Spacer()
                    ZStack {
                        if selected {
                            Circle().fill(.white)
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.cobaltFill)
                        } else {
                            Circle().strokeBorder(Theme.faint, lineWidth: 1.5)
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    if let number {
                        Text(number)
                            .font(Theme.numeral(52))
                            .foregroundStyle(selected ? .white : (warn ? Theme.vermilion : Theme.ink))
                    }
                    Text(caption)
                        .font(Theme.body(13))
                        .foregroundStyle(selected ? .white.opacity(0.78) : Theme.muted)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(selected ? Theme.cobaltFill : Theme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
