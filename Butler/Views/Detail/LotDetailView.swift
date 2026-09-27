import SwiftUI
import SwiftData

struct LotDetailView: View {
    let lotID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var lots: [InventoryLot]
    @Query private var products: [CatalogProduct]
    @Query private var events: [InventoryEvent]

    @State private var capturingDate = false
    @State private var planningDate = false
    @State private var estimatingDate = false
    @State private var clearingDate: LotDateKind?
    @State private var showingHistory = false
    @State private var pendingClose: InventoryLotState?
    @State private var choosingPlace = false
    @State private var errorMessage: String?
    @State private var editingQuantity = false
    @State private var quantityText = ""
    @State private var typingPlace = false
    @State private var placeText = ""

    init(lotID: UUID) {
        self.lotID = lotID
        _lots = Query(filter: #Predicate<InventoryLot> { $0.id == lotID })
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
                    Text(facts?.stateLabel ?? "找不到这条记录")
                        .font(Theme.display(17, weight: .regular))
                        .foregroundStyle(Theme.muted)
                    if let facts {
                        Text(facts.name).font(Theme.display(20))
                        undoButton(facts)
                        Button("查看处理记录") { showingHistory = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingHistory) {
            HistorySheet(events: events).presentationDetents([.medium, .large])
        }
        .alert("没能保存", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Content

    private func content(lot: InventoryLot, facts: LotFacts) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                identity(facts)
                    .padding(.top, 8)
                hero(facts)
                    .padding(.top, 30)
                details(lot: lot, facts: facts)
                    .padding(.top, 34)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions(facts) }
        .fullScreenCover(isPresented: $capturingDate) { DateCaptureView(lot: facts) }
        .sheet(isPresented: $planningDate) {
            PlanDateSheet(name: facts.name, initialDate: lot.plannedUseByDate) { date in
                perform { try $0.setPlannedUseBy(date, for: facts) }
            }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $estimatingDate) {
            PlanDateSheet(name: facts.name, initialDate: lot.estimatedExpiryDate, isEstimate: true) { date in
                perform { try $0.setDate(date, kind: .estimatedExpiry, for: facts) }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog("清除这个日期？原记录仍保留在变动记录里。", isPresented: Binding(
            get: { clearingDate != nil }, set: { if !$0 { clearingDate = nil } }
        ), titleVisibility: .visible) {
            if let kind = clearingDate {
                Button("清除", role: .destructive) {
                    perform { try $0.setDate(nil, kind: kind, for: facts) }
                    clearingDate = nil
                }
            }
        }
        .sheet(isPresented: $editingQuantity) {
            VStack(alignment: .leading, spacing: 20) {
                Text("现在还剩多少？").font(Theme.display(24))
                Text("按完整包装记数；填 0 表示全部用完。")
                TextField("剩余数量", text: $quantityText).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Text(facts.unit)
                Button("确认剩余数量") {
                    guard let quantity = Int(quantityText), quantity >= 0 else { return }
                    if perform({ try $0.adjustQuantity(facts, to: quantity) }) { editingQuantity = false }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(Int(quantityText).map { $0 >= 0 } != true)
                if let errorMessage { Text(errorMessage).foregroundStyle(Theme.vermilion) }
            }
            .padding(24)
            .presentationDetents([.medium])
        }
        .confirmationDialog("放在哪？", isPresented: $choosingPlace, titleVisibility: .visible) {
            ForEach(["冷藏", "冷冻", "常温", "零食柜", "药箱", "卫生间", "储物柜"], id: \.self) { place in
                Button(place) { perform { try $0.move(facts, to: place) } }
            }
            Button("其他地方…") { placeText = ""; typingPlace = true }
        }
        .alert("放在哪？", isPresented: $typingPlace) {
            TextField("例如：阳台柜子", text: $placeText)
            Button("好") {
                let place = placeText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !place.isEmpty { perform { try $0.move(facts, to: place) } }
            }
            Button("取消", role: .cancel) {}
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
                if let brand = facts.brand {
                    Text(brand).font(Theme.body(13)).foregroundStyle(Theme.muted)
                }
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

    // MARK: Hero

    @ViewBuilder
    private func hero(_ facts: LotFacts) -> some View {
        if facts.quantityOnly {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text("还剩")
                        .font(Theme.display(18, weight: .regular))
                        .foregroundStyle(Theme.inkSoft)
                    Text("\(facts.quantity)")
                        .font(Theme.numeral(96))
                        .foregroundStyle(facts.isRunningLow ? Theme.vermilion : Theme.ink)
                    Text(facts.unit)
                        .font(Theme.display(18, weight: .regular))
                        .foregroundStyle(Theme.inkSoft)
                }
                if facts.isRunningLow {
                    Text("快没了，记得补货").font(Theme.body(14, weight: .semibold)).foregroundStyle(Theme.vermilion)
                }
                HStack(spacing: 10) {
                    Button("用掉 1 \(facts.unit)") {
                        perform { try $0.adjustQuantity(facts, to: max(facts.quantity - 1, 0)) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 44))
                    .disabled(facts.quantity == 0)
                    Button("又买了 1 \(facts.unit)") {
                        perform { try $0.adjustQuantity(facts, to: facts.quantity + 1) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 44))
                }
            }
        } else if let days = facts.daysLeft, let end = facts.governingDate {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(days < 0 ? "已超过" : "还有")
                        .font(Theme.display(18, weight: .regular))
                        .foregroundStyle(Theme.inkSoft)
                    Text("\(abs(days))")
                        .font(Theme.numeral(96))
                        .foregroundStyle(days <= 0 ? Theme.vermilion : Theme.ink)
                    Text("天")
                        .font(Theme.display(18, weight: .regular))
                        .foregroundStyle(Theme.inkSoft)
                }
                Text("按\(facts.dateKindLabel) \(end.monthDay) 算").font(Theme.body(14)).foregroundStyle(Theme.muted)
                LifeBar(start: facts.startedAt, end: end, urgent: days <= 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("还不知道\n它哪天到期")
                    .font(Theme.display(30))
                    .foregroundStyle(Theme.ink)
                Button { capturingDate = true } label: {
                    Label("拍一下包装上的日期", systemImage: "camera")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.cobalt)
                }
                Button { setQuantityOnly(true, facts) } label: {
                    Text("不在乎过期？改成只记数量")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: Details

    private func details(lot: InventoryLot, facts: LotFacts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("详情")
                .padding(.bottom, 6)
            detailRow("数量") {
                Button("\(facts.quantity) \(facts.unit)") {
                    quantityText = String(facts.quantity)
                    editingQuantity = true
                }
                .foregroundStyle(Theme.ink)
            }
            if !facts.quantityOnly {
                detailRow("包装上的日期") {
                    if let date = lot.packageExpiryDate {
                        Menu(date.packageStyle) {
                            Button("修改") { capturingDate = true }
                            Button("清除", role: .destructive) { clearingDate = .packageExpiry }
                        }
                        .foregroundStyle(Theme.ink)
                    } else {
                        Button("+ 添加") { capturingDate = true }.foregroundStyle(Theme.cobalt)
                    }
                }
                if let date = lot.estimatedExpiryDate {
                    detailRow("预计到期") {
                        Menu(date.monthDay) {
                            Button("修改") { estimatingDate = true }
                            Button("清除", role: .destructive) { clearingDate = .estimatedExpiry }
                        }
                        .foregroundStyle(Theme.ink)
                    }
                }
                detailRow("打算吃完") {
                    if let date = lot.plannedUseByDate {
                        Menu(date.monthDay + " 前") {
                            Button("修改") { planningDate = true }
                            Button("清除", role: .destructive) { clearingDate = .plannedUseBy }
                        }
                        .foregroundStyle(Theme.ink)
                    } else {
                        Button("+ 设一个") { planningDate = true }.foregroundStyle(Theme.cobalt)
                    }
                }
            }
            detailRow("放在") {
                Button(facts.storageLocation ?? "+ 说一下") { choosingPlace = true }
                    .foregroundStyle(facts.storageLocation == nil ? Theme.cobalt : Theme.ink)
            }
            detailRow("只记数量") {
                Toggle("", isOn: Binding(get: { facts.quantityOnly }, set: { setQuantityOnly($0, facts) }))
                    .labelsHidden()
                    .tint(Theme.cobalt)
            }
            detailRow("变动记录", divider: false) {
                Button("查看") { showingHistory = true }.foregroundStyle(Theme.cobalt)
            }
            if !facts.quantityOnly {
                Text("打开“只记数量”后，不再问过期日期，也不发到期提醒，适合饮用水、纸巾这类东西。")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.faint)
                    .padding(.top, 10)
            }
        }
        .font(Theme.body(15))
    }

    private func detailRow<Content: View>(_ title: String, divider: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 12)
                content()
            }
            .frame(minHeight: 50)
            if divider { Divider().overlay(Theme.hairline) }
        }
    }

    private func setQuantityOnly(_ quantityOnly: Bool, _ facts: LotFacts) {
        do {
            try InventoryActions(modelContainer: modelContext.container).setQuantityOnly(quantityOnly, productID: facts.productID)
            UISelectionFeedbackGenerator().selectionChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Actions

    private func actions(_ facts: LotFacts) -> some View {
        VStack(spacing: 10) {
            undoButton(facts)
            HStack(spacing: 10) {
                Menu {
                    Button("送给别人") { pendingClose = .gifted }
                    Button("丢掉", role: .destructive) { pendingClose = .discarded }
                } label: {
                    Text("丢掉 / 送人")
                        .font(Theme.body(16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Capsule().fill(Theme.surface))
                }
                .frame(maxWidth: 140)
                Button("已经用完了") { pendingClose = .depleted }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.ground.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
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
        perform { try $0.close(facts, as: state) }
    }

    @ViewBuilder
    private func undoButton(_ facts: LotFacts) -> some View {
        if let event = events.first(where: {
            $0.undoQuantity(currentQuantity: facts.quantity, revision: facts.revision) != nil
        }) {
            Button("撤销上一次数量 / 处理操作") { perform { try $0.undo(event, for: facts) } }
                .font(Theme.body(13))
                .foregroundStyle(Theme.cobalt)
        }
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
                .frame(height: 14)
                Text("今天")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(urgent ? Theme.vermilion : Theme.cobalt)
                    .fixedSize()
                    .position(x: min(max(x, 18), proxy.size.width - 18), y: 30)
            }
            .frame(height: 44)
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
    let onSave: (Date) -> Bool
    let isEstimate: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(name: String, initialDate: Date?, isEstimate: Bool = false, onSave: @escaping (Date) -> Bool) {
        self.name = name
        self.onSave = onSave
        self.isEstimate = isEstimate
        _date = State(initialValue: initialDate ?? .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEstimate ? "修改\(name)的估算日期" : "打算哪天前\n用完\(name)？")
                .font(Theme.display(24))
                .foregroundStyle(Theme.ink)
            Text(isEstimate ? "这只是估算，不是包装有效期，也不能保证食用安全。" : "这是你给自己定的小目标，不是包装上的保质期。")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted)
            DatePicker(isEstimate ? "估算日期" : "计划用完", selection: $date, displayedComponents: .date)
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "zh_CN"))
            Spacer()
            Button("定下来") { if onSave(date) { dismiss() } }
                .buttonStyle(PillButtonStyle(kind: .capsule))
        }
        .padding(24)
        .background(Theme.ground.ignoresSafeArea())
    }
}

private struct HistorySheet: View {
    let events: [InventoryEvent]

    var body: some View {
        ScrollView {
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
        case "lotActionUndone": "撤销了上一次处理，库存已恢复"
        default: "有一次变动"
        }
    }
}
