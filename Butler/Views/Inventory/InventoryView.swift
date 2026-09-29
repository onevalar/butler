import SwiftUI

/// 物品: everything at home as big tiles, sorted by category, place or expiry. Tapping a tile opens just
/// that group. Anything finer ("修自行车要用什么", "把这两样挪到…") is asked of the orb.
struct InventoryView: View {
    let facts: [LotFacts]
    var historyCount = 0
    let onOpenGroup: (InventoryGroup.Key) -> Void
    let onOpenHistory: () -> Void

    @AppStorage("inventoryLens") private var lens: InventoryLens = .category
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let groups = InventoryGroups.make(facts, lens: lens)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(groups) { group in
                        Button { onOpenGroup(group.key) } label: { InventoryTile(group: group) }
                            .buttonStyle(.plain)
                    }
                }
                if groups.isEmpty {
                    Text("家里还空着。按住水晶球说一句买了什么，就会出现在这里。")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 24)
                }
                if historyCount > 0 {
                    Button(action: onOpenHistory) {
                        HStack {
                            Text("已处理的东西")
                            Spacer()
                            Text("\(historyCount)").monospacedDigit()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 24)
        }
        .background { ButlerBackground() }
        .compactTitle("物品") {
            Picker("查看方式", selection: $lens) {
                ForEach(InventoryLens.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .animation(reduceMotion ? nil : .snappy, value: lens)
        .sensoryFeedback(.selection, trigger: lens)
    }
}

/// One tile: an icon, the group's name, how many, and the first few things in it.
struct InventoryTile: View {
    let group: InventoryGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: group.symbol)
                    .font(.system(size: 24, weight: .regular))
                    .frame(height: 30, alignment: .topLeading)
                Spacer(minLength: 4)
                if group.urgent > 0 {
                    Text("\(group.urgent)")
                        .font(.footnote.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(group.pressing ? Color.red : Color.orange, in: Capsule())
                        .accessibilityLabel("\(group.urgent) 样需要留意")
                }
            }
            Spacer(minLength: 14)
            Text(group.title)
                .font(.title3.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.8)
            Text("\(group.lots.count) 样").font(.subheadline).foregroundStyle(.secondary)
            Text(group.preview)
                .font(.footnote).foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.top, 5)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .glassCard(radius: 26)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开这一组")
    }
}

/// One group opened from a tile: just the things in it.
struct InventoryGroupView: View {
    let key: InventoryGroup.Key
    let facts: [LotFacts]
    let onOpenLot: (UUID) -> Void

    var body: some View {
        let group = InventoryGroups.group(key, facts: facts)
        ScrollView {
            if let group {
                GroupCard {
                    ForEach(Array(group.lots.enumerated()), id: \.element.id) { index, lot in
                        InventoryRow(lot: lot, showsPlace: !isPlace) { onOpenLot(lot.id) }
                        if index < group.lots.count - 1 { RowDivider(inset: 70) }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 24)
            } else {
                Text("这里已经没有东西了").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .background { ButlerBackground() }
        .compactTitle(InventoryGroups.title(key)) { EmptyView() }
    }

    private var isPlace: Bool {
        if case .place = key { return true }
        return false
    }
}

/// Things that were used up, thrown away or given away.
struct InventoryHistoryView: View {
    let history: [LotFacts]
    let onOpenLot: (UUID) -> Void

    var body: some View {
        ScrollView {
            if history.isEmpty {
                Text("还没有处理过的东西").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                GroupCard {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, lot in
                        InventoryRow(lot: lot, showsState: true) { onOpenLot(lot.id) }
                        if index < history.count - 1 { RowDivider(inset: 70) }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 24)
            }
        }
        .background { ButlerBackground() }
        .compactTitle("已处理的东西") { EmptyView() }
    }
}

extension View {
    /// Back button, a bold title and an optional control on one line, so the content starts right below.
    func compactTitle<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        let control = trailing()
        return navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                ToolbarItem(placement: .topBarLeading) {
                    Text(title).font(.title2.bold()).lineLimit(1).fixedSize()
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
                if !(control is EmptyView) {
                    ToolbarItem(placement: .topBarTrailing) { control }
                }
            }
    }
}

/// One thing: its picture (or its kind's symbol), name and amount, and one plain status on the right.
struct InventoryRow: View {
    let lot: LotFacts
    var showsState = false
    var showsPlace = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ItemPhoto(profile: lot.profile ?? ItemProfile(category: lot.category), size: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lot.name).font(.body).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if !detail.isEmpty {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !status.isEmpty {
                    Text(status).font(.subheadline).foregroundStyle(statusColor).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开详情")
    }

    private var detail: String {
        // A quantity-only thing shows its amount on the right ("剩 6 瓶"); don't say it twice.
        let amount = lot.quantityOnly && !lot.isDurable && !showsState ? nil : "\(lot.quantity) \(lot.unit)"
        let place = showsPlace ? lot.storageLocation.flatMap { $0.isEmpty ? nil : $0 } : nil
        return [lot.brand, amount, place].compactMap { $0 }.joined(separator: " · ")
    }

    private var status: String {
        if showsState { return lot.stateLabel }
        if lot.isDurable {
            let availability = lot.profile?.availability ?? "ready"
            return availability == "ready" ? "" : lot.profile?.availabilityLabel ?? ""
        }
        if lot.quantityOnly { return lot.dateStatusLabel }
        guard let days = lot.daysLeft else { return "待补日期" }
        if days < 0 { return lot.dateStatusLabel }
        return days == 0 ? "今天到期" : "还有 \(lot.timeLeftLabel)"
    }

    private var statusColor: Color {
        if showsState { return .secondary }
        if lot.isDurable { return .orange }
        if lot.quantityOnly { return lot.isRunningLow ? .red : .secondary }
        guard let days = lot.daysLeft else { return .blue }
        return days < 0 ? .red : days <= 3 ? .orange : .secondary
    }
}
