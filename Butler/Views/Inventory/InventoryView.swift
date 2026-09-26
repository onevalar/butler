import SwiftUI

struct InventoryView: View {
    let facts: [LotFacts]
    var history: [LotFacts] = []
    let onOpenLot: (UUID) -> Void
    let onSpeak: () -> Void
    var onCapture: (() -> Void)? = nil

    enum Arrangement: String, CaseIterable { case place = "按位置", expiry = "按到期", kind = "按类别" }

    @State private var arrangement: Arrangement = .place
    @State private var query = ""
    @State private var showingHistory = false

    private var filtered: [LotFacts] {
        (showingHistory ? history : facts).filter { $0.matchesSearch(query) }
    }

    private var groups: [(title: String, lots: [LotFacts])] {
        let lots = filtered
        if showingHistory { return lots.isEmpty ? [] : [("已处理记录", lots)] }
        switch arrangement {
        case .place:
            return Dictionary(grouping: lots) { StorageLocation.groupName(for: $0.storageLocation) }
                .map { ($0.key, $0.value.sorted(by: Self.urgencyOrder)) }
                .sorted { StorageLocation.sortKey($0.title) < StorageLocation.sortKey($1.title) }
        case .expiry:
            let buckets: [(String, (LotFacts) -> Bool)] = [
                ("今天以前", { $0.tier <= .today }),
                ("这周", { $0.tier == .soon || $0.tier == .week }),
                ("以后", { $0.tier == .calm }),
                ("还没日期", { $0.tier == .undated }),
            ]
            return buckets.compactMap { title, test in
                let hit = lots.filter(test).sorted(by: Self.urgencyOrder)
                return hit.isEmpty ? nil : (title, hit)
            }
        case .kind:
            let medicine = lots.filter(\.isMedicine).sorted(by: Self.urgencyOrder)
            let rest = lots.filter { !$0.isMedicine }.sorted(by: Self.urgencyOrder)
            return [("吃的用的", rest), ("药品", medicine)].filter { !$0.1.isEmpty }
        }
    }

    private static func urgencyOrder(_ a: LotFacts, _ b: LotFacts) -> Bool {
        (a.daysLeft ?? .max, a.name) < (b.daysLeft ?? .max, b.name)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(groups, id: \.title) { group in
                        shelf(group.title, lots: group.lots)
                            .padding(.top, 24)
                    }
                    if groups.isEmpty {
                        Text(query.isEmpty ? (showingHistory ? "还没有处理记录" : "家里还空着") : "没有匹配“\(query)”的记录")
                            .font(Theme.display(17, weight: .regular))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 130)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)

            Dock(onShelf: nil, onSpeak: onSpeak, onCapture: onCapture)
        }
        .background(Theme.ground.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .lastTextBaseline) {
                Text("家里的东西")
                    .font(Theme.display(34))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\((showingHistory ? history : facts).count)")
                    .font(Theme.numeral(38))
                    .foregroundStyle(Theme.cobalt)
                Text("件")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted)
            }
            Picker("库存范围", selection: $showingHistory) {
                Text("在库").tag(false)
                Text("已处理").tag(true)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.muted)
                TextField("", text: $query, prompt: Text("搜索名称、品牌或位置").foregroundStyle(Theme.muted))
                    .font(Theme.display(15, weight: .regular))
                    .foregroundStyle(Theme.ink)
                    .submitLabel(.search)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Capsule().fill(Theme.surface))
            HStack(spacing: 22) {
                ForEach(Arrangement.allCases, id: \.self) { option in
                    Button { arrangement = option } label: {
                        Text(option.rawValue)
                            .font(Theme.body(15, weight: arrangement == option ? .semibold : .regular))
                            .foregroundStyle(arrangement == option ? Theme.ink : Theme.muted)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) {
                                if arrangement == option { Rectangle().fill(Theme.ink).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .padding(.top, 6)
    }

    private func shelf(_ title: String, lots: [LotFacts]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.ink)
                Text("\(lots.count)")
                    .font(Theme.numeral(17))
                    .foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), alignment: .leading, spacing: 14) {
                ForEach(lots) { lot in
                    Button { onOpenLot(lot.id) } label: {
                        VStack(spacing: 6) {
                            SealView(glyph: lot.glyph, style: SealStyle(tier: lot.tier), size: 50)
                            VStack(spacing: 1) {
                                Text(lot.name)
                                    .font(Theme.body(11))
                                    .foregroundStyle(Theme.inkSoft)
                                Text(showingHistory ? lot.stateLabel : lot.dateStatusLabel)
                                    .font(Theme.body(11, weight: lot.tier <= .soon ? .semibold : .regular))
                                    .foregroundStyle(labelColor(lot.tier))
                            }
                            .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lot.name)，\(lot.quantity)\(lot.unit)，\(showingHistory ? lot.stateLabel : lot.dateStatusLabel)")
                }
            }
        }
    }

    private func labelColor(_ tier: UrgencyTier) -> Color {
        switch tier {
        case .overdue, .today: Theme.vermilion
        case .soon, .week: Theme.cobalt
        default: Theme.muted
        }
    }
}
