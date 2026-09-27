import SwiftUI
import SwiftData

/// One item: how long it has left (or how many are left), quick actions, and its details.
struct LotDetailView: View {
    let lotID: UUID

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
                closedState
            }
        }
        .background { ButlerBackground() }
        .sheet(isPresented: $showingHistory) {
            HistorySheet(events: events).presentationDetents([.medium, .large])
        }
        .alert("没能保存", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var closedState: some View {
        ContentUnavailableView {
            Label(facts?.name ?? "找不到这条记录", systemImage: "checkmark.circle")
        } description: {
            Text(facts?.stateLabel ?? "它可能已经被删除了")
        } actions: {
            if let facts {
                undoButton(facts)
                Button("查看变动记录") { showingHistory = true }
            }
        }
    }

    // MARK: Content

    private func content(lot: InventoryLot, facts: LotFacts) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                status(facts)
                quickActions(facts)
                details(lot: lot, facts: facts)
                    .padding(.top, 12)
                VStack(spacing: 0) {
                    DetailRow(title: "变动记录", value: "\(events.count) 条") { showingHistory = true }
                    if hasUndo(facts) {
                        RowDivider(inset: 16)
                        undoButton(facts)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                }
                .padding(.vertical, 4)
                .glassCard(radius: 26)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .orbScrollTracking()
        .navigationTitle(facts.name)
        .navigationSubtitle(subtitle(facts))
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingHistory = true } label: { Label("变动记录", systemImage: "clock.arrow.circlepath") }
                    Button { pendingClose = .gifted } label: { Label("送给别人", systemImage: "gift") }
                    Button(role: .destructive) { pendingClose = .discarded } label: { Label("丢掉", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .fullScreenCover(isPresented: $capturingDate) { DateCaptureView(lot: facts) }
        .sheet(isPresented: $planningDate) {
            DatePickSheet(title: "打算哪天前吃完", note: "这是你给自己定的计划，不是包装上的保质期。",
                          initial: lot.plannedUseByDate) { date in perform { try $0.setPlannedUseBy(date, for: facts) } }
        }
        .sheet(isPresented: $estimatingDate) {
            DatePickSheet(title: "预计到期", note: "这只是估算，不是包装有效期，也不能保证食用安全。",
                          initial: lot.estimatedExpiryDate) { date in perform { try $0.setDate(date, kind: .estimatedExpiry, for: facts) } }
        }
        .sheet(isPresented: $editingQuantity) {
            QuantitySheet(name: facts.name, unit: facts.unit, initial: facts.quantity) { quantity in
                perform { try $0.adjustQuantity(facts, to: quantity) }
            }
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
                    perform { try $0.close(facts, as: state) }
                }
            }
            Button("再想想", role: .cancel) { pendingClose = nil }
        }
    }

    private func subtitle(_ facts: LotFacts) -> String {
        var parts: [String] = []
        if let brand = facts.brand { parts.append(brand) }
        if let place = facts.storageLocation { parts.append(place) }
        parts.append("\(facts.startedAt.monthDay)买入")
        parts.append("\(facts.quantity) \(facts.unit)")
        return parts.joined(separator: " · ")
    }

    // MARK: Status

    @ViewBuilder
    private func status(_ facts: LotFacts) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if facts.quantityOnly {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("还剩").font(.subheadline).foregroundStyle(.secondary)
                    Text("\(facts.quantity)")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .foregroundStyle(facts.isRunningLow ? .red : .primary)
                        .contentTransition(.numericText())
                    Text(facts.unit).font(.body)
                }
                Text(facts.isRunningLow ? "快没了，记得补货" : "只记数量，不提醒到期")
                    .font(.subheadline)
                    .foregroundStyle(facts.isRunningLow ? .red : .secondary)
            } else if let days = facts.daysLeft, let end = facts.governingDate {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(days < 0 ? "已过期" : "还有").font(.subheadline).foregroundStyle(.secondary)
                    Text("\(abs(days))")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .foregroundStyle(days <= 0 ? .red : days <= 3 ? .orange : .primary)
                        .contentTransition(.numericText())
                    Text(days < 0 ? "天" : "天到期").font(.body)
                }
                ProgressView(value: progress(from: facts.startedAt, to: end))
                    .tint(days <= 0 ? .red : days <= 3 ? .orange : .blue)
                HStack {
                    Text("\(facts.startedAt.monthDay) 买入")
                    Spacer()
                    Text("\(end.monthDay) \(facts.dateKindLabel)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text("还不知道它哪天到期").font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    Button { capturingDate = true } label: { Label("拍包装上的日期", systemImage: "camera") }
                        .buttonStyle(AccentButtonStyle())
                        .fixedSize()
                    Button("只记数量") { setQuantityOnly(true, facts) }
                        .buttonStyle(.bordered)
                }
                .buttonBorderShape(.capsule)
            }
            if facts.isMedicine {
                Label("药品 · 处理前都会先问你", systemImage: "cross.case")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 26)
    }

    private func progress(from start: Date, to end: Date) -> Double {
        let total = max(end.timeIntervalSince(start), 1)
        return min(max(Date.now.timeIntervalSince(start) / total, 0), 1)
    }

    // MARK: Quick actions

    private func quickActions(_ facts: LotFacts) -> some View {
        HStack(spacing: 10) {
            ActionTile(title: "用掉 1 \(facts.unit)", systemImage: "minus") { useOne(facts) }
            if facts.quantityOnly {
                ActionTile(title: "又买了 1 \(facts.unit)", systemImage: "plus") {
                    perform { try $0.adjustQuantity(facts, to: facts.quantity + 1) }
                }
                ActionTile(title: "全部用完", systemImage: "checkmark") { pendingClose = .depleted }
            } else {
                ActionTile(title: "全部用完", systemImage: "checkmark") { pendingClose = .depleted }
                ActionTile(title: "丢掉", systemImage: "trash", tint: .red) { pendingClose = .discarded }
            }
        }
        .sensoryFeedback(.success, trigger: facts.quantity)
    }

    private func useOne(_ facts: LotFacts) {
        if facts.quantity <= 1 {
            pendingClose = .depleted
        } else {
            withAnimation(.snappy) { _ = perform { try $0.adjustQuantity(facts, to: facts.quantity - 1) } }
        }
    }

    // MARK: Details

    private func details(lot: InventoryLot, facts: LotFacts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("详情").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            VStack(spacing: 0) {
                DetailRow(title: "数量", value: "\(facts.quantity) \(facts.unit)") { editingQuantity = true }
                if !facts.quantityOnly {
                    RowDivider(inset: 16)
                    dateRow("包装上的日期", date: lot.packageExpiryDate, text: lot.packageExpiryDate?.packageStyle,
                            edit: { capturingDate = true }, clear: { clearingDate = .packageExpiry })
                    if lot.estimatedExpiryDate != nil {
                        RowDivider(inset: 16)
                        dateRow("预计到期", date: lot.estimatedExpiryDate, text: lot.estimatedExpiryDate?.monthDay,
                                edit: { estimatingDate = true }, clear: { clearingDate = .estimatedExpiry })
                    }
                    RowDivider(inset: 16)
                    dateRow("打算吃完", date: lot.plannedUseByDate, text: lot.plannedUseByDate?.monthDay,
                            edit: { planningDate = true }, clear: { clearingDate = .plannedUseBy })
                }
                RowDivider(inset: 16)
                DetailRow(title: "放在", value: facts.storageLocation ?? "未设置") { choosingPlace = true }
                RowDivider(inset: 16)
                Toggle("只记数量", isOn: Binding(get: { facts.quantityOnly }, set: { setQuantityOnly($0, facts) }))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
            }
            .padding(.vertical, 4)
            .glassCard(radius: 26)
            Text("打开后不再提醒到期，只记还剩多少。适合饮用水、纸巾这类东西。")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func dateRow(_ title: String, date: Date?, text: String?,
                         edit: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        if date != nil, let text {
            Menu {
                Button("修改", action: edit)
                Button("清除", role: .destructive, action: clear)
            } label: {
                DetailRowLabel(title: title, value: text)
            }
            .buttonStyle(.plain)
        } else {
            DetailRow(title: title, value: "未设置", action: edit)
        }
    }

    private func setQuantityOnly(_ quantityOnly: Bool, _ facts: LotFacts) {
        do {
            try InventoryActions(modelContainer: modelContext.container).setQuantityOnly(quantityOnly, productID: facts.productID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Closing and undo

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

    private func undoEvent(_ facts: LotFacts) -> InventoryEvent? {
        events.first { $0.undoQuantity(currentQuantity: facts.quantity, revision: facts.revision) != nil }
    }

    private func hasUndo(_ facts: LotFacts) -> Bool { undoEvent(facts) != nil }

    @ViewBuilder
    private func undoButton(_ facts: LotFacts) -> some View {
        if let event = undoEvent(facts) {
            Button("撤销上一次数量 / 处理") { perform { try $0.undo(event, for: facts) } }
        }
    }

    @discardableResult
    private func perform(_ work: (InventoryActions) throws -> Void) -> Bool {
        do {
            try work(InventoryActions(modelContainer: modelContext.container))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Rows and tiles

private struct DetailRowLabel: View {
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { DetailRowLabel(title: title, value: value) }
            .buttonStyle(.plain)
    }
}

private struct ActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color = .blue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 20, weight: .medium)).foregroundStyle(tint)
                    .frame(height: 26)
                Text(title).font(.footnote).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .glassCard(radius: 22)
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheets

private struct DatePickSheet: View {
    let title: String
    let note: String
    let onSave: (Date) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(title: String, note: String, initial: Date?, onSave: @escaping (Date) -> Bool) {
        self.title = title
        self.note = note
        self.onSave = onSave
        _date = State(initialValue: initial ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(title, selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                } footer: {
                    Text(note)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { if onSave(date) { dismiss() } } }
            }
        }
        .presentationDetents([.large])
    }
}

private struct QuantitySheet: View {
    let name: String
    let unit: String
    let onSave: (Int) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var quantity: Int

    init(name: String, unit: String, initial: Int, onSave: @escaping (Int) -> Bool) {
        self.name = name
        self.unit = unit
        self.onSave = onSave
        _quantity = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $quantity, in: 0...999) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(quantity)").font(.title.weight(.semibold)).monospacedDigit()
                                .contentTransition(.numericText())
                            Text(unit).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("按完整包装记数；改成 0 表示全部用完。")
                }
            }
            .navigationTitle("\(name)还剩多少").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { if onSave(quantity) { dismiss() } } }
            }
            .animation(.snappy, value: quantity)
        }
        .presentationDetents([.height(260)])
    }
}

private struct HistorySheet: View {
    let events: [InventoryEvent]

    var body: some View {
        NavigationStack {
            List(events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.describe(event))
                    Text(event.occurredAt.monthDayTime).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if events.isEmpty { ContentUnavailableView("还没有变动", systemImage: "clock") }
            }
            .navigationTitle("变动记录").navigationBarTitleDisplayMode(.inline)
        }
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
