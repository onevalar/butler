import SwiftUI

/// 家庭 › 共享与提醒规则: what the butler follows when deciding who sees, does and is reminded of things,
/// and this person's quiet hours. Rules are mostly made by talking; here they can be read and removed.
struct HouseholdRulesPage: View {
    @State private var adding: Bool?
    @State private var text = ""
    private var store: HouseholdStore { .shared }
    private var service: HouseholdService { .shared }

    var body: some View {
        Form {
            Section {
                if store.rules.isEmpty {
                    Text("还没有。比如“缴费的事都交给老婆”“孩子的事全家都能看到”。").foregroundStyle(.secondary)
                }
                ForEach(store.rules) { rule in ruleRow(rule) }
                    .onDelete { offsets in offsets.map { store.rules[$0].id }.forEach(service.removeRule) }
                Button("添加家里的规则", systemImage: "plus") { text = ""; adding = false }
            } header: {
                Text("家里的规则")
            } footer: {
                Text("全家共用，家人那边也能看到。")
            }
            .glassRows()

            Section {
                if store.myRules.isEmpty {
                    Text("还没有。比如“我的体检和看病只给我看”“老婆完成的事告诉我”。").foregroundStyle(.secondary)
                }
                ForEach(store.myRules) { rule in ruleRow(rule) }
                    .onDelete { offsets in offsets.map { store.myRules[$0].id }.forEach(service.removeRule) }
                Button("添加只对我的规则", systemImage: "plus") { text = ""; adding = true }
            } header: {
                Text("只对我")
            } footer: {
                Text("只存在这台手机上，家人看不到。和家里的规则冲突时，以这里为准。")
            }
            .glassRows()

            Section {
                QuietHoursRow(quiet: store.me?.quiet) { service.setQuiet($0) }
            } header: {
                Text("免打扰")
            } footer: {
                Text("家人交给你的事、提醒你一下、完成通知，在这段时间里不响，结束时再提醒；你自己定的提醒照常。")
            }
            .glassRows()

            Section {
                Text("平时直接跟管家说就行，比如“以后买菜的事都交给我”“别让孩子看到礼物的事”。你在卡片上改过的决定，管家也会问要不要记成规则。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
        .glassList()
        .compactTitle("共享与提醒规则") { EmptyView() }
        .alert(adding == true ? "只对我的规则" : "家里的规则", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            TextField("用一句话说清楚", text: $text)
            Button("添加") {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if (2...200).contains(value.count) { service.addRule(value, forMe: adding == true) }
                adding = nil
            }
            Button("取消", role: .cancel) { adding = nil }
        }
    }

    private func ruleRow(_ rule: HouseholdRule) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(rule.text)
            if let who = store.member(rule.createdBy), who.id != store.state?.me {
                Text("\(HouseholdStore.shared.displayName(who))加的").font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions { Button("删除", role: .destructive) { service.removeRule(rule.id) } }
    }
}

/// On / off, and from when to when.
private struct QuietHoursRow: View {
    let quiet: QuietHours?
    let apply: (QuietHours?) -> Void

    var body: some View {
        Toggle("每天免打扰", isOn: Binding(get: { quiet != nil },
                                         set: { apply($0 ? QuietHours(start: 22 * 60, end: 7 * 60) : nil) }))
        if let quiet {
            DatePicker("开始", selection: binding(quiet.start) { QuietHours(start: $0, end: quiet.end) },
                       displayedComponents: .hourAndMinute)
            DatePicker("结束", selection: binding(quiet.end) { QuietHours(start: quiet.start, end: $0) },
                       displayedComponents: .hourAndMinute)
        }
    }

    private func binding(_ minutes: Int, _ make: @escaping (Int) -> QuietHours) -> Binding<Date> {
        let day = Calendar.current.startOfDay(for: .now)
        return Binding(get: { day.addingTimeInterval(Double(minutes) * 60) }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let value = make((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            if value.start != value.end { apply(value) }
        })
    }
}
