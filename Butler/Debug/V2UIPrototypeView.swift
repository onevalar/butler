#if DEBUG
import SwiftUI

// This prototype deliberately owns only local value types. It must not become a persistence client.
struct PrototypeProduct: Identifiable, Hashable {
    let id: UUID
    var name: String
    var category: String
    var lots: [PrototypeLot]

    var total: Int { lots.reduce(0) { $0 + $1.quantity } }
}

struct PrototypeLot: Identifiable, Hashable {
    let id: UUID
    var quantity: Int
    var unit: String
    var location: String
    var packageExpiry: String?
    var estimatedExpiry: String?
    var plannedUseBy: String?
}

struct PrototypeReviewItem: Identifiable {
    let id = UUID()
    var name: String
    var quantity: Int
    var unit: String
    var location: String
}

private enum PrototypeTodayState: String, CaseIterable, Identifiable {
    case content = "内容"
    case empty = "空状态"
    case error = "错误"
    var id: Self { self }
}

struct V2UIPrototypeView: View {
    @State private var showingInput = false
    @State private var products = PrototypeFixtures.products

    var body: some View {
        TabView {
            PrototypeTodayView { showingInput = true }
                .tabItem { Label("今日", systemImage: "sun.max") }
            PrototypeInventoryView(products: $products) { showingInput = true }
                .tabItem { Label("库存", systemImage: "shippingbox") }
            PrototypeTimelineView { showingInput = true }
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
        }
        .sheet(isPresented: $showingInput) { PrototypeInputSheet() }
    }
}

private struct PrototypeTodayView: View {
    let add: () -> Void
    @State private var state: PrototypeTodayState = .content

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .content:
                    List {
                        Section("待确认") {
                            PrototypeActionRow(icon: "questionmark.circle", title: "冰激凌放在哪里？", detail: "冷藏或冷冻会影响预计日期")
                            PrototypeActionRow(icon: "calendar.badge.exclamationmark", title: "确认牛奶包装日期", detail: "识别为 8 月 6 日，需确认")
                        }
                        Section("临期") {
                            PrototypeActionRow(icon: "exclamationmark.triangle", title: "鲜牛奶 · 1 瓶", detail: "包装有效期：明天")
                            PrototypeActionRow(icon: "leaf", title: "生菜 · 1 袋", detail: "预计有效期：还有 2 天")
                        }
                        Section("计划使用") {
                            PrototypeActionRow(icon: "checklist", title: "方便面 · 1 包", detail: "计划今天使用，不代表食品安全期限")
                        }
                    }
                case .empty:
                    ContentUnavailableView("今天没有待办", systemImage: "checkmark.circle", description: Text("新增物品后，风险与计划会出现在这里。"))
                case .error:
                    ContentUnavailableView {
                        Label("暂时无法加载", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("这是用于验证恢复路径的模拟错误。")
                    } actions: {
                        Button("重试") { state = .content }
                    }
                }
            }
            .navigationTitle("今日")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Debug 状态", systemImage: "ladybug") {
                        Picker("今日状态", selection: $state) {
                            ForEach(PrototypeTodayState.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    .accessibilityLabel("切换今日调试状态")
                }
                ToolbarItem(placement: .topBarTrailing) { AddButton(action: add) }
            }
        }
    }
}

private struct PrototypeActionRow: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: icon).foregroundStyle(.tint) }
        .accessibilityElement(children: .combine)
    }
}

private struct PrototypeInventoryView: View {
    @Binding var products: [PrototypeProduct]
    let add: () -> Void
    @State private var search = ""

    private var filtered: [PrototypeProduct] {
        search.isEmpty ? products : products.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { product in
                NavigationLink(value: product.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.name).font(.headline)
                        Text("\(product.category) · 共 \(product.total) 件 · \(product.lots.count) 个批次")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .overlay {
                if filtered.isEmpty { ContentUnavailableView.search(text: search) }
            }
            .searchable(text: $search, prompt: "搜索产品或分类")
            .navigationTitle("库存")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AddButton(action: add) } }
            .navigationDestination(for: UUID.self) { id in
                if let index = products.firstIndex(where: { $0.id == id }) {
                    PrototypeProductDetail(product: $products[index])
                }
            }
        }
    }
}

private struct PrototypeProductDetail: View {
    @Binding var product: PrototypeProduct
    var body: some View {
        List {
            Section {
                LabeledContent("产品", value: product.name)
                LabeledContent("聚合库存", value: "\(product.total) 件")
            } footer: { Text("产品回答“这是什么”；数量和日期属于下面的批次。") }
            ForEach($product.lots) { $lot in
                Section("批次 · \(lot.location)") {
                    Stepper("数量：\(lot.quantity) \(lot.unit)", value: $lot.quantity, in: 0...99)
                        .accessibilityValue("\(lot.quantity) \(lot.unit)")
                    Button("使用一个") { lot.quantity = max(0, lot.quantity - 1) }
                        .disabled(lot.quantity == 0)
                    DisclosureGroup("调整数量") {
                        HStack {
                            Button("减少") { lot.quantity = max(0, lot.quantity - 1) }.disabled(lot.quantity == 0)
                            Spacer()
                            Button("增加") { lot.quantity += 1 }
                        }
                    }
                    DateSemanticRows(lot: lot)
                }
            }
        }
        .navigationTitle(product.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DateSemanticRows: View {
    let lot: PrototypeLot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日期语义").font(.headline)
            LabeledContent("包装有效期", value: lot.packageExpiry ?? "未提供")
            LabeledContent("预计有效期", value: lot.estimatedExpiry ?? "未估算")
            LabeledContent("计划使用日", value: lot.plannedUseBy ?? "未计划")
            Text("预计值不是包装结论；计划日期不是食品安全结论。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PrototypeTimelineView: View {
    let add: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section("今天") {
                    TimelineRow(icon: "minus.circle", title: "使用了鲜牛奶 1 瓶", detail: "鲜牛奶 · 冷藏批次", time: "09:20")
                    TimelineRow(icon: "plus.circle", title: "添加 3 件物品", detail: "牛奶、方便面、冰激凌", time: "08:45")
                }
                Section("昨天") {
                    TimelineRow(icon: "slider.horizontal.3", title: "数量调整 2 → 3", detail: "抽纸 · 储物柜批次", time: "19:10")
                    TimelineRow(icon: "calendar", title: "设置计划使用日", detail: "方便面 · 8 月 5 日", time: "12:30")
                }
            }
            .navigationTitle("记录")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AddButton(action: add) } }
        }
    }
}

private struct TimelineRow: View {
    let icon: String, title: String, detail: String, time: String
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(.tint).imageScale(.large)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(time).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AddButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("添加", systemImage: "plus") }
            .accessibilityHint("打开统一录入")
    }
}

private enum PrototypeInputStep { case input, parsing, clarification, review, saving, success }

private struct PrototypeInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = "我买了一瓶牛奶、三包方便面和一个冰激凌，冰激凌先放冰箱。"
    @State private var step: PrototypeInputStep = .input
    @State private var items = PrototypeFixtures.reviewItems
    @State private var errorMessage: String?
    @State private var simulateFailure = false

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .input: inputSection
                case .parsing: Section { ProgressView("正在模拟理解输入…") }
                case .clarification: clarificationSection
                case .review, .saving: reviewSections
                case .success:
                    Section {
                        Label("模拟保存成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("原型没有写入任何数据库。").foregroundStyle(.secondary)
                        Button("完成") { dismiss() }
                    }
                }
            }
            .navigationTitle("统一录入")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(step != .input && step != .success)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private var inputSection: some View {
        Section("输入") {
            TextField("描述物品、数量和日期", text: $text, axis: .vertical).lineLimit(3...7)
            Text("文字、语音、图片、订单最终进入同一审核流程；此原型只模拟文字。")
                .font(.caption).foregroundStyle(.secondary)
            Button("模拟解析") {
                step = .parsing
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    step = .clarification
                }
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var clarificationSection: some View {
        Section("精确追问") {
            Text("“冰箱”指冷藏还是冷冻？")
            Text("储存方式会影响冰激凌的预计有效期，因此不能静默推断。")
                .font(.caption).foregroundStyle(.secondary)
            Button("冷藏") { answerIceCream("冷藏") }
            Button("冷冻（建议）") { answerIceCream("冷冻") }
        }
    }

    private var reviewSections: some View {
        Group {
            Section("最终审核") {
                Text("三个建议均可编辑；模拟值不会持久化。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($items) { $item in
                Section(item.name) {
                    TextField("产品名称", text: $item.name)
                    Stepper("数量：\(item.quantity) \(item.unit)", value: $item.quantity, in: 1...99)
                    TextField("储存位置", text: $item.location)
                }
            }
            Section("Debug 保存结果") {
                Toggle("模拟保存失败", isOn: $simulateFailure)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Text("审核内容和输入 session 已保留，可修改后重试。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(step == .saving ? "正在模拟保存…" : "确认并模拟保存") { save() }
                    .disabled(step == .saving || items.contains { $0.name.isEmpty })
            }
        }
    }

    private func answerIceCream(_ location: String) {
        if let index = items.firstIndex(where: { $0.name == "冰激凌" }) { items[index].location = location }
        step = .review
    }

    private func save() {
        errorMessage = nil
        step = .saving
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            if simulateFailure {
                errorMessage = "模拟数据库保存失败，未写入任何内容"
                step = .review
            } else { step = .success }
        }
    }
}

private enum PrototypeFixtures {
    static let products = [
        PrototypeProduct(id: UUID(), name: "鲜牛奶", category: "食品和饮料", lots: [
            PrototypeLot(id: UUID(), quantity: 1, unit: "瓶", location: "冷藏", packageExpiry: "2026/8/3", estimatedExpiry: nil, plannedUseBy: "2026/8/2"),
            PrototypeLot(id: UUID(), quantity: 2, unit: "瓶", location: "冷藏", packageExpiry: "2026/8/8", estimatedExpiry: nil, plannedUseBy: nil)
        ]),
        PrototypeProduct(id: UUID(), name: "方便面", category: "食品和饮料", lots: [
            PrototypeLot(id: UUID(), quantity: 3, unit: "包", location: "常温", packageExpiry: nil, estimatedExpiry: "2027/1/10", plannedUseBy: "2026/8/5")
        ]),
        PrototypeProduct(id: UUID(), name: "抽纸", category: "家庭日用品", lots: [
            PrototypeLot(id: UUID(), quantity: 3, unit: "提", location: "储物柜", packageExpiry: nil, estimatedExpiry: nil, plannedUseBy: nil)
        ])
    ]

    static let reviewItems = [
        PrototypeReviewItem(name: "鲜牛奶", quantity: 1, unit: "瓶", location: "冷藏"),
        PrototypeReviewItem(name: "方便面", quantity: 3, unit: "包", location: "常温"),
        PrototypeReviewItem(name: "冰激凌", quantity: 1, unit: "个", location: "待确认")
    ]
}
#endif
