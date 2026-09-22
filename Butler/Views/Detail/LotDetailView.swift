import SwiftUI
import SwiftData

struct LotDetailView: View {
    let lotID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var lots: [InventoryLot]
    @Query private var products: [CatalogProduct]
    @Query private var evidence: [FieldEvidence]
    @Query private var events: [InventoryEvent]

    @State private var capturingDate = false
    @State private var planningDate = false
    @State private var showingHistory = false
    @State private var pendingClose: InventoryLotState?
    @State private var choosingPlace = false
    @State private var errorMessage: String?

    init(lotID: UUID) {
        self.lotID = lotID
        _lots = Query(filter: #Predicate<InventoryLot> { $0.id == lotID })
        _evidence = Query(filter: #Predicate<FieldEvidence> { $0.subjectID == lotID },
                          sort: \FieldEvidence.createdAt, order: .reverse)
        _events = Query(filter: #Predicate<InventoryEvent> { $0.subjectID == lotID },
                        sort: \InventoryEvent.occurredAt, order: .reverse)
    }

    private var lot: InventoryLot? { lots.first }
    private var facts: LotFacts? {
        guard let lot else { return nil }
        return LotFacts(lot: lot, product: products.first { $0.id == lot.productID })
    }

    var body: some View {
        Group {
            if let lot, let facts, lot.state == .active {
                content(lot: lot, facts: facts)
            } else {
                VStack(spacing: 12) {
                    SealView(glyph: "完", style: .quiet, size: 60)
                    Text("这件东西已经处理好了")
                        .font(Theme.display(17, weight: .regular))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .alert("没能保存", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Content

    private func content(lot: InventoryLot, facts: LotFacts) -> some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    identity(facts)
                        .padding(.top, 8)
                    countdown(facts)
                        .padding(.top, 30)
                    ledger(lot: lot, facts: facts)
                        .padding(.top, 30)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 150)
            }
            .scrollIndicators(.hidden)
            actions(facts)
        }
        .fullScreenCover(isPresented: $capturingDate) { DateCaptureView(lot: facts) }
        .sheet(isPresented: $planningDate) {
            PlanDateSheet(name: facts.name) { date in perform { try $0.setPlannedUseBy(date, for: facts) } }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingHistory) {
            HistorySheet(events: events).presentationDetents([.medium, .large])
        }
        .confirmationDialog("放在哪？", isPresented: $choosingPlace, titleVisibility: .visible) {
            ForEach(["冷藏", "冷冻", "常温", "零食柜", "药箱"], id: \.self) { place in
                Button(place) { perform { try $0.move(facts, to: place) } }
            }
        }
        .confirmationDialog(closeTitle(facts), isPresented: .constant(pendingClose != nil), titleVisibility: .visible) {
            if let state = pendingClose {
                Button(closeVerb(state), role: state == .discarded ? .destructive : nil) {
                    pendingClose = nil
                    close(facts, as: state)
                }
            }
            Button("再想想", role: .cancel) { pendingClose = nil }
        }
    }

    private func identity(_ facts: LotFacts) -> some View {
        HStack(alignment: .center, spacing: 18) {
            SealView(glyph: facts.glyph, style: .outline, size: 84, tilt: -4)
            VStack(alignment: .leading, spacing: 6) {
                Text(facts.name)
                    .font(Theme.display(24))
                    .foregroundStyle(Theme.ink)
                Text([facts.brand, "\(facts.quantity) \(facts.unit)"].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted)
                if facts.isMedicine {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.vermilion).frame(width: 5, height: 5)
                        Text("药品 · 处理前都会先问你")
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(Theme.vermilion)
                    }
                }
            }
        }
    }

    // MARK: Countdown

    @ViewBuilder
    private func countdown(_ facts: LotFacts) -> some View {
        if let days = facts.daysLeft, let end = facts.governingDate {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(days < 0 ? "已经过期" : "还有")
                        .font(Theme.display(18, weight: .regular))
                        .foregroundStyle(Theme.inkSoft)
                    Text("\(abs(days))")
                        .font(Theme.numeral(96))
                        .foregroundStyle(days <= 0 ? Theme.vermilion : Theme.ink)
                    Text(days < 0 ? "天" : (facts.governingDateKind == .plannedUseBy ? "天该吃完" : "天到期"))
                        .font(Theme.display(18, weight: .regular))
                        .foregroundStyle(Theme.inkSoft)
                }
                LifeBar(start: facts.startedAt, end: end, urgent: days <= 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("还不知道\n它哪天到期")
                    .font(Theme.display(30))
                    .foregroundStyle(Theme.ink)
                Button { capturingDate = true } label: {
                    Label("拍一下包装上的日期", systemImage: "camera")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.cobalt)
                }
            }
        }
    }

    // MARK: Ledger

    private func ledger(lot: InventoryLot, facts: LotFacts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("三个日期，各管各的")
                .padding(.bottom, 6)
            ledgerRow("包装有效期") {
                if let date = lot.packageExpiryDate {
                    Text(date.packageStyle)
                        .font(Theme.numeral(20, italic: false))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    sourceBadge(for: .packageExpiryDate)
                } else {
                    Button("+ 拍一下") { capturingDate = true }
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.cobalt)
                    Spacer()
                    Text("不会替你猜")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted)
                }
            }
            ledgerRow("我的估算") {
                if let date = lot.estimatedExpiryDate {
                    InferredText(text: date.monthDay, inferred: true, font: Theme.body(14))
                } else {
                    Text(lot.packageExpiryDate == nil ? "没有估算" : "不需要，已有包装日期")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
            }
            ledgerRow("计划用完") {
                if let date = lot.plannedUseByDate {
                    let source = latest(.plannedUseByDate)
                    InferredText(text: date.monthDay + "前",
                                 inferred: source?.isInferred ?? false, font: Theme.body(14))
                    Spacer()
                    sourceBadge(for: .plannedUseByDate)
                } else {
                    Button("+ 设一个") { planningDate = true }
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.cobalt)
                    Spacer()
                }
            }
            ledgerRow("放在", divider: false) {
                Button { choosingPlace = true } label: {
                    InferredText(text: facts.storageLocation ?? "还没说",
                                 inferred: latest(.storageLocation)?.isInferred ?? (facts.storageLocation == nil),
                                 font: Theme.body(14))
                }
                .buttonStyle(.plain)
                Spacer()
                sourceBadge(for: .storageLocation)
            }
        }
    }

    private func ledgerRow<Content: View>(_ title: String, divider: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(title)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 92, alignment: .leading)
                content()
            }
            .frame(minHeight: 46)
            if divider { Divider().overlay(Theme.hairline) }
        }
    }

    @ViewBuilder
    private func sourceBadge(for field: InventoryFieldKey) -> some View {
        if let record = latest(field) {
            HStack(spacing: 4) {
                if record.isConfirmed {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                }
                Text(record.label)
                    .font(Theme.body(12, weight: .medium))
            }
            .foregroundStyle(record.isConfirmed ? Theme.cobalt : Theme.muted)
            .padding(.horizontal, record.isConfirmed ? 8 : 0)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(record.isConfirmed ? Theme.surface : .clear))
        }
    }

    private struct SourceRecord {
        let source: EvidenceSourceKind
        let isConfirmed: Bool
        var isInferred: Bool { source.isInference && !isConfirmed }
        var label: String { isConfirmed ? "\(source.label) · 你确认过" : source.label }
    }

    private func latest(_ field: InventoryFieldKey) -> SourceRecord? {
        guard let record = evidence.first(where: { $0.fieldKey == field.rawValue }),
              let source = EvidenceSourceKind(rawValue: record.sourceKindRawValue) else { return nil }
        return SourceRecord(source: source,
                            isConfirmed: record.verificationStateRawValue == EvidenceVerificationState.userConfirmed.rawValue)
    }

    // MARK: Actions

    private func actions(_ facts: LotFacts) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Button("丢掉") { pendingClose = .discarded }
                    .buttonStyle(PillButtonStyle(kind: .outlineDanger))
                    .frame(maxWidth: 120)
                Button("已经用完了") {
                    if facts.isMedicine { pendingClose = .depleted } else { close(facts, as: .depleted) }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
            HStack(spacing: 22) {
                Button("来龙去脉") { showingHistory = true }
                Button("送给别人") { pendingClose = .gifted }
            }
            .font(Theme.body(13))
            .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            LinearGradient(colors: [Theme.ground.opacity(0), Theme.ground], startPoint: .top, endPoint: .init(x: 0.5, y: 0.26))
                .ignoresSafeArea()
        }
    }

    private func closeTitle(_ facts: LotFacts) -> String {
        switch pendingClose {
        case .discarded: "把\(facts.name)丢掉？"
        case .gifted: "把\(facts.name)送给别人？"
        default: "\(facts.name)用完了？"
        }
    }

    private func closeVerb(_ state: InventoryLotState) -> String {
        switch state {
        case .discarded: "丢掉"
        case .gifted: "送出去了"
        default: "用完了"
        }
    }

    private func close(_ facts: LotFacts, as state: InventoryLotState) {
        if perform({ try $0.close(facts, as: state) }) { dismiss() }
    }

    @discardableResult
    private func perform(_ work: (InventoryActions) throws -> Void) -> Bool {
        do {
            try work(InventoryActions(modelContainer: modelContext.container))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Life bar

private struct LifeBar: View {
    let start: Date
    let end: Date
    let urgent: Bool

    var body: some View {
        let total = max(end.timeIntervalSince(start), 1)
        let progress = min(max(Date.now.timeIntervalSince(start) / total, 0), 1)
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let x = proxy.size.width * progress
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline).frame(height: 4)
                    Capsule().fill(urgent ? Theme.vermilion : Theme.cobalt).frame(width: x, height: 4)
                    Circle()
                        .strokeBorder(urgent ? Theme.vermilion : Theme.cobalt, lineWidth: 3)
                        .background(Circle().fill(Theme.ground))
                        .frame(width: 14, height: 14)
                        .offset(x: min(max(x - 7, 0), proxy.size.width - 14))
                }
                .frame(maxHeight: .infinity)
                Text("今天")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(urgent ? Theme.vermilion : Theme.cobalt)
                    .fixedSize()
                    .position(x: min(max(x, 18), proxy.size.width - 18), y: 30)
            }
            .frame(height: 14)
            HStack {
                Text(start.monthDay + " 买入")
                Spacer()
                Text(end.monthDay)
            }
            .font(Theme.body(12))
            .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Sheets

private struct PlanDateSheet: View {
    let name: String
    let onSave: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("打算哪天前\n吃完\(name)？")
                .font(Theme.display(24))
                .foregroundStyle(Theme.ink)
            Text("这是你给自己定的小目标，不是包装上的保质期。")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted)
            DatePicker("计划用完", selection: $date, in: Date.now..., displayedComponents: .date)
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "zh_CN"))
            Spacer()
            Button("定下来") { onSave(date); dismiss() }
                .buttonStyle(PillButtonStyle(kind: .capsule))
        }
        .padding(24)
        .background(Theme.ground.ignoresSafeArea())
    }
}

private struct HistorySheet: View {
    let events: [InventoryEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("来龙去脉")
                .font(Theme.display(24))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 18)
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(index == 0 ? Theme.cobalt : Theme.ground)
                            .overlay(Circle().strokeBorder(Theme.cobalt, lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .padding(.top, 5)
                        if index < events.count - 1 {
                            Rectangle().fill(Theme.dashed).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.describe(event))
                            .font(Theme.body(14, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Text(event.occurredAt.monthDayTime)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.bottom, 18)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ground.ignoresSafeArea())
    }

    static func describe(_ event: InventoryEvent) -> String {
        switch event.eventTypeRawValue {
        case "lotAdded": "记进来了"
        case "lotDateSet": "日期更新了"
        case "lotMoved": "换了个地方放"
        case "quantityAdjusted": "数量变了"
        case "lotClosed": "处理掉了"
        default: "有一次变动"
        }
    }
}
