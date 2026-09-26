import SwiftUI
import SwiftData

struct HomeView: View {
    let facts: [LotFacts]
    let onOpenLot: (UUID) -> Void
    let onOpenShelf: () -> Void
    let onSpeak: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var datingLot: LotFacts?
    @State private var errorMessage: String?

    private let calendar = Calendar.current

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Masthead()
                        .padding(.top, 6)
                    greeting
                        .padding(.top, 30)
                    if facts.isEmpty {
                        EmptyHome()
                            .padding(.top, 36)
                    } else {
                        WeekStrip(facts: facts, onOpenLot: onOpenLot)
                            .padding(.top, 30)
                        if !asks.isEmpty {
                            asksSection
                                .padding(.top, 26)
                        }
                        calmLine
                            .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 130)
            }
            .scrollIndicators(.hidden)

            Dock(onShelf: facts.isEmpty ? nil : onOpenShelf, onSpeak: onSpeak)
        }
        .background(Theme.ground.ignoresSafeArea())
        .fullScreenCover(item: $datingLot) { lot in
            DateCaptureView(lot: lot)
        }
        .alert("没能保存", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(salutation)
                .font(Theme.display(52))
                .foregroundStyle(Theme.ink)
                .tracking(-1)
            Text(summary)
                .font(Theme.display(20, weight: .regular))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var salutation: String {
        switch calendar.component(.hour, from: Date()) {
        case 5..<11: "早安。"
        case 11..<14: "午安。"
        case 14..<18: "下午好。"
        default: "晚上好。"
        }
    }

    private var summary: String {
        if facts.isEmpty { return "家里还空着，\n说一句你买了什么，我来记。" }
        var lines: [String] = []
        let due = facts.filter { $0.tier <= .today }.sorted { ($0.daysLeft ?? 0) < ($1.daysLeft ?? 0) }
        if let first = due.first {
            if due.count > 1 {
                lines.append("\(first.name)：\(first.dateStatusLabel)，共 \(due.count) 样需要查看")
            } else {
                lines.append("\(first.name)：\(first.dateStatusLabel)")
            }
        }
        if !asks.isEmpty {
            lines.append("还有 \(asks.count) 样东西在等你一句话。")
        }
        if lines.isEmpty {
            let week = facts.filter { $0.tier <= .week }.count
            return week > 0 ? "这周有 \(week) 样需要查看，\n记得核对包装和实际状态。" : "这周没有日期提醒。"
        }
        if lines.count == 1, !lines[0].hasSuffix("。") { lines[0] += "。" }
        return lines.joined(separator: "，\n")
    }

    // MARK: Asks

    private var asks: [LotFacts] {
        facts.filter { $0.needsCompartment || $0.needsDate }
    }

    private var asksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("等你一句话")
                .padding(.bottom, 6)
            ForEach(Array(asks.prefix(3).enumerated()), id: \.element.id) { index, lot in
                AskRow(
                    lot: lot,
                    onPhoto: { datingLot = lot },
                    onCompartment: { choose(lot, $0) },
                    onOpen: { onOpenLot(lot.id) }
                )
                if index < min(asks.count, 3) - 1 {
                    Divider().overlay(Theme.hairline)
                }
            }
            if asks.count > 3 {
                Button("还有 \(asks.count - 3) 件 →", action: onOpenShelf)
                    .font(Theme.body(13, weight: .medium))
                    .foregroundStyle(Theme.cobalt)
                    .padding(.top, 8)
            }
        }
    }

    private func choose(_ lot: LotFacts, _ choice: InventoryStorageChoice) {
        do {
            try InventoryActions(modelContainer: modelContext.container).move(lot, to: choice.rawValue)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var calmLine: some View {
        let calm = facts.filter { $0.tier == .calm }.count
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(calm)")
                .font(Theme.numeral(20))
                .foregroundStyle(Theme.cobalt)
            Text(calm == facts.count ? "件东西都安好，不用操心" : "件其它东西都安好，不用操心")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted)
        }
        .opacity(calm > 0 ? 1 : 0)
    }
}

// MARK: - Masthead

private struct Masthead: View {
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            HStack(spacing: 8) {
                Text("管")
                    .font(Theme.display(13))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.cobaltFill))
                Text("BUTLER")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3.5)
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(Date.now.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US"))))
                    .font(Theme.numeral(22))
                    .foregroundStyle(Theme.ink)
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - Week strip

private struct WeekStrip: View {
    let facts: [LotFacts]
    let onOpenLot: (UUID) -> Void

    private let calendar = Calendar.current
    private static let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    private var byOffset: [Int: [LotFacts]] {
        var result: [Int: [LotFacts]] = [:]
        for lot in facts {
            guard let days = lot.daysLeft, days <= 6 else { continue }
            result[max(days, 0), default: []].append(lot)
        }
        return result.mapValues { $0.sorted { $0.tier < $1.tier } }
    }

    var body: some View {
        let grouped = byOffset
        let count = grouped.values.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("这一周要留意的")
                Spacer()
                Text(count == 0 ? "没有" : "\(count) 件")
                    .font(Theme.body(13, weight: .medium))
                    .foregroundStyle(Theme.cobalt)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<7, id: \.self) { offset in
                    dayColumn(offset: offset, lots: grouped[offset] ?? [])
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
        }
    }

    private func dayColumn(offset: Int, lots: [LotFacts]) -> some View {
        let date = calendar.date(byAdding: .day, value: offset, to: .now) ?? .now
        let isToday = offset == 0
        let label = isToday ? "今天" : Self.weekdayNames[calendar.component(.weekday, from: date) - 1]
        let dayColor: Color = isToday && !lots.isEmpty ? Theme.vermilion : (lots.isEmpty ? Theme.faint : Theme.ink)
        return VStack(spacing: 10) {
            Text(label)
                .font(Theme.body(11, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Theme.vermilion : Theme.muted)
            Text("\(calendar.component(.day, from: date))")
                .font(Theme.numeral(28, italic: false))
                .foregroundStyle(dayColor)
            VStack(spacing: 6) {
                ForEach(Array(lots.prefix(2).enumerated()), id: \.element.id) { index, lot in
                    Button { onOpenLot(lot.id) } label: {
                        SealView(glyph: lot.glyph, style: SealStyle(tier: lot.tier), size: 40,
                                 tilt: lot.tier <= .today ? -4 : (lot.tier == .week ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lot.name)，\(lot.dateStatusLabel)")
                }
                if lots.count > 2 {
                    Text("+\(lots.count - 2)")
                        .font(Theme.numeral(15))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

// MARK: - Ask row

private struct AskRow: View {
    let lot: LotFacts
    let onPhoto: () -> Void
    let onCompartment: (InventoryStorageChoice) -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: lot.needsCompartment ? .top : .center, spacing: 14) {
            Button(action: onOpen) {
                SealView(glyph: lot.glyph, style: .quiet, size: 40)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.display(16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted)
                if lot.needsCompartment {
                    HStack(spacing: 8) {
                        ChoiceChip(title: "冷冻", selected: true) { onCompartment(.frozen) }
                        ChoiceChip(title: "冷藏") { onCompartment(.refrigerated) }
                    }
                    .padding(.top, 10)
                }
            }
            Spacer(minLength: 0)
            if !lot.needsCompartment {
                Button(action: onPhoto) {
                    Image(systemName: "camera")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.cobaltFill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("拍下\(lot.name)的日期")
            }
        }
        .padding(.vertical, 14)
    }

    private var title: String {
        lot.needsCompartment ? "\(lot.name)放哪一层？" : "\(lot.name)哪天过期？"
    }

    private var subtitle: String {
        if lot.needsCompartment { return "决定它能放两天还是两个月" }
        return lot.isMedicine ? "药盒上印着，拍一下就好" : "包装上印着，拍一下就好"
    }
}

// MARK: - Empty state

private struct EmptyHome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                SealView(glyph: "奶", style: .missing, size: 52, tilt: -4)
                SealView(glyph: "面", style: .missing, size: 52)
                SealView(glyph: "药", style: .missing, size: 52, tilt: 3)
            }
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("试试这样说", color: Theme.muted)
                Text("“买了一瓶牛奶，还有三包方便面”")
                    .font(Theme.display(17, weight: .regular))
                    .foregroundStyle(Theme.cobalt)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
    }
}
