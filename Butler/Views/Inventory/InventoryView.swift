import SwiftUI

/// 家里的东西: every item grouped by place or by expiry, with search floating at the bottom.
struct InventoryView: View {
    let facts: [LotFacts]
    var history: [LotFacts] = []
    let onOpenLot: (UUID) -> Void
    let onChat: (ChatStart) -> Void

    enum Scope: String, CaseIterable { case place = "按位置", expiry = "按到期", history = "已处理" }

    @State private var scope: Scope = .place
    @State private var query = ""
    @FocusState private var searching: Bool

    private var filtered: [LotFacts] {
        (scope == .history ? history : facts).filter { $0.matchesSearch(query) }
    }

    private var groups: [(title: String, lots: [LotFacts])] {
        let lots = filtered
        switch scope {
        case .history:
            return lots.isEmpty ? [] : [("已处理", lots)]
        case .place:
            return Dictionary(grouping: lots) { lot in
                let place = StorageLocation.groupName(for: lot.storageLocation)
                return lot.quantityOnly ? "\(place) · 只记数量" : place
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
        .background(Color(.systemGroupedBackground))
        .navigationTitle("家里的东西")
        .navigationSubtitle("\(facts.count) 样在家")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaBar(edge: .bottom) { searchBar }
        .animation(.snappy, value: scope)
    }

    private var emptyText: String {
        if !query.isEmpty { return "没有找到“\(query)”" }
        return scope == .history ? "还没有处理过的东西" : "家里还空着，跟管家说一句买了什么"
    }

    /// iOS 26 puts search at the bottom, in reach of the thumb.
    private var searchBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索名称、品牌或位置", text: $query)
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
                .padding(.horizontal, 18)
                .frame(height: 52)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button { onChat(.typing) } label: {
                    Image(systemName: "plus").font(.system(size: 19, weight: .medium)).frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("跟管家说买了什么")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
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
                KindBar(color: barColor, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lot.name).font(.body).foregroundStyle(.primary).lineLimit(1)
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
