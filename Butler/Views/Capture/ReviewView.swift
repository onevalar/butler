import SwiftUI

/// 核对: the butler's handwritten receipt. Nothing is saved until "就这样，记下吧".
struct ReviewView: View {
    let coordinator: InventoryInputCoordinator
    let onAddMore: () -> Void
    let onBack: () -> Void
    @State private var editing: Entry?

    private struct Entry: Identifiable {
        let id: UUID
        let productID: UUID
        let name: String
        let glyph: Character
        let isExisting: Bool
        let isMedicine: Bool
        let quantity: Int
        let quantityInferred: Bool
        let unit: String
        let storage: String?
        let storageInferred: Bool
        let purchasedAt: Date?
        let estimatedExpiry: Date?
        let estimatedInferred: Bool
        let packageExpiry: Date?
        let plannedUseBy: Date?
        let plannedInferred: Bool
    }

    private var lines: [Entry] {
        guard let plan = coordinator.reviewPlan else { return [] }
        return plan.operations.compactMap { planned in
            guard case .addLot(let lot) = planned.operation else { return nil }
            let name = coordinator.productDisplays[lot.productID]?.canonicalName ?? "未命名"
            let medicine = LotGlyph.isMedicine(name: name, category: nil)
            let source = { (key: InventoryFieldKey) in lot.evidence.first { $0.fieldKey == key }?.source }
            return Entry(
                id: lot.lotID, productID: lot.productID, name: name,
                glyph: LotGlyph.glyph(for: name, isMedicine: medicine),
                isExisting: coordinator.existingProductIDs.contains(lot.productID),
                isMedicine: medicine,
                quantity: lot.quantity,
                quantityInferred: source(.quantity)?.isInference ?? false,
                unit: lot.unit,
                storage: lot.storageLocation,
                storageInferred: source(.storageLocation)?.isInference ?? false,
                purchasedAt: lot.purchasedAt,
                estimatedExpiry: lot.estimatedExpiryDate,
                estimatedInferred: source(.estimatedExpiryDate)?.isInference ?? false,
                packageExpiry: lot.packageExpiryDate,
                plannedUseBy: lot.plannedUseByDate,
                plannedInferred: source(.plannedUseByDate)?.isInference ?? false
            )
        }
    }

    var body: some View {
        let lines = lines
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 32, height: 32, alignment: .leading)
                        }
                        .accessibilityLabel("重新说")
                        Spacer()
                        Text(Date.now.stamp)
                            .font(Theme.numeral(18))
                            .foregroundStyle(Theme.muted)
                    }
                    Text("我记下了这些，\n你看对不对？")
                        .font(Theme.display(30))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(6)
                        .padding(.top, 20)
                    legend
                        .padding(.top, 14)
                        .padding(.bottom, 22)

                    VStack(spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            row(line)
                            if index < lines.count - 1 {
                                Line()
                                    .stroke(Theme.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                    .frame(height: 1.5)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))

                    Button(action: onAddMore) {
                        Label("漏了什么？接着说", systemImage: "mic")
                            .font(Theme.display(15, weight: .regular))
                            .foregroundStyle(Theme.cobalt)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 150)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 12) {
                Button(coordinator.state == .executing ? "正在记…" : "就这样，记下吧") {
                    coordinator.confirmAndExecute()
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 58))
                .disabled(coordinator.state == .executing)
                if let missing = lines.first(where: { $0.packageExpiry == nil && $0.plannedUseBy == nil && $0.estimatedExpiry == nil }) {
                    Text("\(missing.name)的日期，拍好后再补也可以")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 8)
            .background(alignment: .top) {
                LinearGradient(colors: [Theme.ground.opacity(0), Theme.ground], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3))
                    .ignoresSafeArea()
            }
        }
        .disabled(coordinator.state == .executing)
        .sheet(item: $editing) { entry in
            if let draft = coordinator.reviewDraft(lotID: entry.id) {
                CaptureReviewEditor(draft: draft) { edited in
                    coordinator.editReview(lotID: entry.id, draft: edited)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("正常字").font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("你说的").font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 6) {
                InferredText(text: "蓝色虚线", inferred: true, font: Theme.body(13, weight: .semibold))
                Text("我推断的").font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func row(_ line: Entry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SealView(glyph: line.glyph, style: .paper, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(line.name)
                        .font(Theme.display(17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if !line.isExisting {
                        Text("NEW")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.9)
                            .foregroundStyle(Theme.cobalt)
                    }
                    Spacer()
                    InferredText(text: "×\(line.quantity)\(line.unit)", inferred: line.quantityInferred,
                                 font: Theme.numeral(24, italic: false))
                }
                Button("编辑") { editing = line }
                    .font(Theme.body(13, weight: .medium))
                    .accessibilityLabel("编辑\(line.name)")
                HStack(spacing: 6) {
                    if let storage = line.storage {
                        InferredText(text: storage, inferred: line.storageInferred)
                    } else {
                        Text("还没说放哪").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                    if line.isExisting {
                        Text("· 家里已有同款").font(Theme.body(13)).foregroundStyle(Theme.muted)
                        if coordinator.autoLinked[line.productID] != nil {
                            // Linked without asking; one tap makes it a separate product instead.
                            Button("改") { coordinator.keepSeparate(fromExisting: line.productID) }
                                .font(Theme.body(13, weight: .medium))
                                .foregroundStyle(Theme.cobalt)
                                .buttonStyle(.plain)
                                .accessibilityLabel("不是同一种，改成新的")
                        }
                    }
                    if let planned = line.plannedUseBy {
                        Text("·").font(Theme.body(13)).foregroundStyle(Theme.muted)
                        InferredText(text: planned.monthDay + "前吃完", inferred: line.plannedInferred)
                    }
                }
                if let expiry = line.packageExpiry {
                    Text("包装有效期 \(expiry.formatted(date: .abbreviated, time: .omitted)) · 保存时由你确认")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted)
                } else if line.plannedUseBy != nil {
                    Text(line.plannedInferred ? "这是我建议的计划日期，不是包装上的保质期" : "这是你的计划日期，不是包装上的保质期")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted)
                } else {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.vermilion).frame(width: 6, height: 6)
                        Text("还差包装有效期")
                            .font(Theme.body(13, weight: .semibold))
                            .foregroundStyle(Theme.vermilion)
                        Text("· 我不会替你猜")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 2)
                }
                if let estimated = line.estimatedExpiry {
                    InferredText(text: "估算到期 \(estimated.formatted(date: .abbreviated, time: .omitted))（非包装日期）",
                                 inferred: line.estimatedInferred)
                }
                if let purchased = line.purchasedAt {
                    Text("购买日期 \(purchased.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.vertical, 16)
    }
}
