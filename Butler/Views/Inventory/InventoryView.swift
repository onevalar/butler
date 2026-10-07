import SwiftUI

/// Grouping and presentation are independent: every visible card still opens one item.
struct InventoryView: View {
    let facts: [LotFacts]
    var historyCount = 0
    let onOpenLot: (UUID) -> Void
    let onOpenHistory: () -> Void

    @State private var query = ""
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var cancelWidth = 44
    @AppStorage("inventoryLens") private var lens: InventoryLens = .category
    @AppStorage("inventoryListLayout") private var listLayout = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 156), spacing: 10, alignment: .top)]
    }

    var body: some View {
        let items = InventoryCatalog.items(facts, query: query)
        let groups = InventoryGroups.make(items, lens: lens)
        VStack(spacing: 0) {
            header
            inventoryContent(items: items, groups: groups)
        }
        .background { ButlerBackground() }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func inventoryContent(items: [LotFacts], groups: [InventoryGroup]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !facts.isEmpty || !query.isEmpty {
                    HStack(spacing: 8) {
                        Text(query.isEmpty ? "\(items.count) 样物品" : "找到 \(items.count) 样物品")
                            .accessibilityAction(named: "搜索物品") { openSearch() }
                        if !query.isEmpty && !showsSearch {
                            Text("· \(query)").lineLimit(1)
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("清除搜索")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                if items.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "把家里的物品记在这里" : "没有找到物品",
                              systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass")
                    } description: {
                        Text(query.isEmpty ? "告诉小当家你买了什么，名称、数量和存放位置都会记在这里。" : "试试其他名称或位置。")
                    } actions: {
                        if !query.isEmpty { Button("查看全部物品") { query = "" } }
                    }
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if groups.count > 1 {
                                HStack {
                                    Text(sectionTitle(group)).font(.subheadline.weight(.semibold))
                                    Text("\(group.lots.count)").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
                            }
                            if listLayout {
                                LazyVStack(spacing: 8) {
                                    ForEach(group.lots) { lot in itemButton(lot, list: true) }
                                }
                            } else {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                                    ForEach(group.lots) { lot in itemButton(lot, list: false) }
                                }
                            }
                        }
                    }
                }
                if historyCount > 0 {
                    Button(action: onOpenHistory) {
                        HStack {
                            Text("已处理的物品")
                            Spacer()
                            Text("\(historyCount)").monospacedDigit()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectHidden(for: .top)
        .clipped()
    }

    // One persistent glass surface and magnifier travel from the tools capsule to
    // the input. The row and the results never move as the keyboard arrives.
    private var header: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let searchWidth = max(96, width - cancelWidth - 12)
            let surfaceWidth = showsSearch ? searchWidth : 96
            let surfaceX = showsSearch ? 0 : width - 96
            let motion: Animation? = reduceMotion ? nil : .smooth(duration: 0.38)

            ZStack(alignment: .leading) {
                browsingTitle
                    .opacity(showsSearch ? 0 : 1)
                    .animation(browsingContentAnimation, value: showsSearch)
                    .allowsHitTesting(!showsSearch)
                    .accessibilityHidden(showsSearch)

                Capsule().fill(.clear)
                    .frame(width: surfaceWidth, height: 44)
                    .glassEffect(.regular, in: Capsule())
                    .offset(x: surfaceX)
                    .animation(motion, value: showsSearch)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Button {
                    if showsSearch { searchFocused = true } else { openSearch() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .medium))
                        .scaleEffect(showsSearch ? 0.85 : 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: showsSearch ? 2 : width - 92)
                .animation(motion, value: showsSearch)
                .accessibilityLabel("搜索物品")

                moreMenu
                    .offset(x: width - 48)
                    .opacity(showsSearch ? 0 : 1)
                    .animation(browsingContentAnimation, value: showsSearch)
                    .allowsHitTesting(!showsSearch)
                    .accessibilityHidden(showsSearch)

                searchField
                    .frame(width: searchWidth - 58, height: 44)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .offset(x: showsSearch ? 0 : width - 96)
                            .animation(motion, value: showsSearch)
                    }
                    .offset(x: 44)
                    .opacity(showsSearch ? 1 : 0)
                    .animation(searchContentAnimation, value: showsSearch)
                    .allowsHitTesting(showsSearch)
                    .accessibilityHidden(!showsSearch)

                Button("取消", action: closeSearch)
                    .font(.body).fixedSize().frame(width: cancelWidth, height: 44)
                    .offset(x: width - cancelWidth)
                    .opacity(showsSearch ? 1 : 0)
                    .animation(searchContentAnimation, value: showsSearch)
                    .allowsHitTesting(showsSearch)
                    .accessibilityHidden(!showsSearch)
                    .accessibilityLabel("取消搜索")
            }
            .foregroundStyle(.primary)
        }
        .frame(height: 44)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .task(id: showsSearch) {
            guard showsSearch else { return }
            // Start the keyboard during expansion, after the title has begun to yield.
            // The view-owned task is cancelled on close/disappearance or a new search.
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
            }
            guard !Task.isCancelled, showsSearch else { return }
            searchFocused = true
        }
    }

    private var browsingContentAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return showsSearch
            ? .easeOut(duration: 0.12)
            : .easeOut(duration: 0.22).delay(0.12)
    }

    private var searchContentAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return showsSearch
            ? .easeOut(duration: 0.22).delay(0.12)
            : .easeOut(duration: 0.12)
    }

    private var browsingTitle: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("返回")
            Text("物品").font(.title2.bold()).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
        }
    }

    private var moreMenu: some View {
        Menu {
            Section("分组方式") {
                Picker("分组方式", selection: $lens) {
                    ForEach(InventoryLens.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            }
            Section("显示方式") {
                Picker("显示方式", selection: $listLayout) {
                    Label("网格", systemImage: "square.grid.2x2").tag(false)
                    Label("列表", systemImage: "list.bullet").tag(true)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多选项")
        .accessibilityValue("按\(lens.rawValue)分组，\(listLayout ? "列表" : "网格")显示")
    }

    private func openSearch() {
        showsSearch = true
    }

    private func closeSearch() {
        searchFocused = false
        query = ""
        showsSearch = false
    }

    private func itemButton(_ lot: LotFacts, list: Bool) -> some View {
        Button { onOpenLot(lot.id) } label: { InventoryItemCard(lot: lot, listLayout: list) }
            .buttonStyle(.plain)
    }

    private func sectionTitle(_ group: InventoryGroup) -> String {
        switch group.key {
        case .expiry(.expired): "已到日期"
        case .expiry(.thisWeek): "未来 7 天"
        case .expiry(.later): "更晚"
        case .expiry(.noDate): "未记录日期"
        case .expiry(.quantityOnly): "其他物品"
        default: group.title
        }
    }


    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("搜索物品、位置", text: $query)
                .focused($searchFocused)
                .submitLabel(.search).autocorrectionDisabled()
                .accessibilityLabel("搜索物品、位置")
                .onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除搜索")
            }
        }
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
                    // The segmented control has its own track; the toolbar's glass behind it made two layers.
                    ToolbarItem(placement: .topBarTrailing) { control }
                        .sharedBackgroundVisibility(.hidden)
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
