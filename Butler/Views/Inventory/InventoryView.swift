import SwiftUI

/// 家里: every item grouped by place or by expiry, quick questions, and search in the header.
struct InventoryView: View {
    let facts: [LotFacts]
    var history: [LotFacts] = []
    let onOpenLot: (UUID) -> Void
    let onChat: (ChatStart) -> Void
    /// Opens the conversation with a sentence already started.
    let onAsk: (String) -> Void

    enum Scope: String, CaseIterable { case category = "按分类", place = "按位置", expiry = "按到期", history = "已处理" }

    @State private var scope: Scope = .category
    @State private var query = ""
    @State private var showingSearch = false
    @FocusState private var searching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let quickAsks = ["买了", "用完了", "放哪了？", "什么快过期了？", "今天穿什么？", "家里有适合修东西的工具吗？"]

    private var dueThisWeek: Int {
        facts.filter { !$0.quantityOnly && (0...7).contains($0.daysLeft ?? -1) }.count
    }

    private var filtered: [LotFacts] {
        (scope == .history ? history : facts).filter { $0.matchesSearch(query) }
    }

    private var groups: [(title: String, lots: [LotFacts])] {
        let lots = filtered
        switch scope {
        case .category:
            return ItemCategory.allCases.compactMap { category in
                let found = lots.filter { $0.category == category }.sorted(by: Self.urgencyOrder)
                return found.isEmpty ? nil : (category.title, found)
            }
        case .history:
            return lots.isEmpty ? [] : [("已处理", lots)]
        case .place:
            return Dictionary(grouping: lots) { lot in
                let place = StorageLocation.groupName(for: lot.storageLocation)
                return place
            }
            .map { ($0.key, $0.value.sorted(by: Self.urgencyOrder)) }
            .sorted { StorageLocation.sortKey($0.title) < StorageLocation.sortKey($1.title) }
        case .expiry:
            let buckets: [(String, (LotFacts) -> Bool)] = [
                ("已经过期", { !$0.quantityOnly && ($0.daysLeft ?? 1) < 0 }),
                ("这周", { !$0.quantityOnly && (0...7).contains($0.daysLeft ?? -1) }),
                ("以后", { !$0.quantityOnly && ($0.daysLeft ?? 0) > 7 }),
                ("还没日期", { $0.needsDate }),
                ("只记数量", { $0.quantityOnly }),
            ]
            return buckets.compactMap { title, test in
                let hit = lots.filter(test).sorted(by: Self.urgencyOrder)
                return hit.isEmpty ? nil : (title, hit)
            }
        }
    }

    private static func urgencyOrder(_ a: LotFacts, _ b: LotFacts) -> Bool {
        (a.daysLeft ?? .max, a.name) < (b.daysLeft ?? .max, b.name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showingSearch { searchField.padding(.horizontal, 16) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.quickAsks, id: \.self) { ask in
                            Button { onAsk(ask) } label: {
                                Text(ask.hasSuffix("？") ? "“\(ask)”" : "“\(ask)…”").font(.subheadline)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 2)
                }
                Picker("显示方式", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text("\(group.lots.count) 样")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 22)
                        GroupCard {
                            ForEach(Array(group.lots.enumerated()), id: \.element.id) { index, lot in
                                InventoryRow(lot: lot, showsState: scope == .history) { onOpenLot(lot.id) }
                                if index < group.lots.count - 1 { RowDivider(inset: 36) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if groups.isEmpty {
                    Text(emptyText)
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .background { ButlerBackground() }
        .navigationTitle("家里")
        .navigationSubtitle(dueThisWeek > 0 ? "\(facts.count) 样在家 · 本周 \(dueThisWeek) 样到期" : "\(facts.count) 样在家")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingSearch.toggle()
                    if showingSearch { searching = true } else { query = "" }
                } label: {
                    Image(systemName: showingSearch ? "xmark" : "magnifyingglass")
                }
                .accessibilityLabel(showingSearch ? "关闭搜索" : "搜索")
                Button { onChat(.typing) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("跟管家说买了什么")
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: scope)
        .animation(reduceMotion ? nil : .snappy, value: showingSearch)
    }

    private var emptyText: String {
        if !query.isEmpty { return "没有找到“\(query)”" }
        return scope == .history ? "还没有处理过的东西" : "家里还空着，跟管家说一句买了什么"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称、位置、用途或属性", text: $query)
                .focused($searching)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }
}

/// One item: a colour bar for its urgency, name and amount, and how long it has left.
struct InventoryRow: View {
    let lot: LotFacts
    var showsState = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if lot.isDurable || lot.profile?.photo != nil {
                    ItemPhoto(profile: lot.profile ?? ItemProfile(category: lot.category), size: 44)
                } else { KindBar(color: barColor, height: 34) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(lot.name).font(.body).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(status).font(.subheadline).foregroundStyle(statusColor).lineLimit(1)
            }
            .padding(.leading, 16).padding(.trailing, 16).padding(.vertical, 9)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开详情")
    }

    private var detail: String {
        [lot.brand, "\(lot.quantity) \(lot.unit)"].compactMap { $0 }.joined(separator: " · ")
    }

    private var status: String {
        if showsState { return lot.stateLabel }
        if lot.quantityOnly { return lot.dateStatusLabel }
        guard let days = lot.daysLeft else { return "待补日期" }
        if days < 0 { return "已过期 \(-days) 天" }
        return days == 0 ? "今天到期" : lot.timeLeftLabel
    }

    private var barColor: Color {
        if showsState { return .gray }
        if lot.quantityOnly { return lot.isRunningLow ? .red : .gray }
        guard let days = lot.daysLeft else { return .gray }
        return days <= 0 ? .red : days <= 7 ? .orange : .gray
    }

    private var statusColor: Color {
        if showsState { return .secondary }
        if lot.quantityOnly { return lot.isRunningLow ? .red : .secondary }
        guard let days = lot.daysLeft else { return .blue }
        return days <= 0 ? .red : days <= 3 ? .orange : .secondary
    }
}
