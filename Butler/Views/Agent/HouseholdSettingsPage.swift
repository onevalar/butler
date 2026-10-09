import CloudKit
import SwiftUI
import UIKit

/// 管家与设置 › 家庭: create the household, invite the family, see who is in it, leave.
struct HouseholdSettingsPage: View {
    @State private var creating = false
    @State private var confirmLeave = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var error: String?
    private var service: HouseholdService { .shared }
    private var store: HouseholdStore { .shared }

    var body: some View {
        Form {
            if let state = store.state {
                if let summary = service.summary {
                    Section { HouseholdSummaryCard(summary: summary) { service.summary = nil } }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(store.members) { member in
                        Button {
                            guard member.id == state.me else { return }
                            newName = member.name
                            renaming = true
                        } label: {
                            HStack(spacing: 12) {
                                MemberBadge(member: member)
                                Text(member.name).foregroundStyle(.primary)
                                if member.id == state.me { Text("我").font(.footnote).foregroundStyle(.secondary) }
                                Spacer()
                                if member.isOwner { Text("创建者").font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if store.isOwner {
                        Button { invite() } label: { Label("邀请家人", systemImage: "person.badge.plus") }
                    }
                } header: {
                    Text(state.name)
                } footer: {
                    Text(syncLine)
                }
                .glassRows()

                Section {
                    NavigationLink { HouseholdRulesPage() } label: {
                        HStack(spacing: 8) {
                            Text("共享与提醒规则")
                            Spacer(minLength: 12)
                            Text(rulesSummary).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .glassRows()

                Section {
                    Text("家里的东西全家都能看到，谁记的、谁改的都会标明；个人的药、护肤品、礼物等由管家判断只留给你自己。想改的话点开那样东西，或者直接跟管家说“这个只给我看”。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                Section {
                    Button(store.isOwner ? "解散家庭" : "退出家庭", role: .destructive) { confirmLeave = true }
                }
                .glassRows()
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("和家人一起用").font(.title3.bold())
                        Text("建立家庭后，家里的东西全家共享：谁买了、谁用了、放在哪，大家看到的都一样。你自己的对话、私密的任务和东西仍然只属于你。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("家庭资料存在你的 iCloud 里，家人用自己的 Apple ID 加入，不用另外注册。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    Button { creating = true } label: { Label("建立家庭", systemImage: "house") }
                }
                .glassRows()
            }
        }
        .glassList()
        .compactTitle("家庭") { EmptyView() }
        .sheet(isPresented: $creating) { CreateHouseholdSheet() }
        .alert("家人怎么称呼你？", isPresented: $renaming) {
            TextField("例如“妈妈”“老公”", text: $newName)
            Button("好") { service.rename(me: newName) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(store.isOwner ? "解散这个家庭？" : "退出这个家庭？", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(store.isOwner ? "解散" : "退出", role: .destructive) {
                Task {
                    do { try await service.leave() } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text(store.isOwner
                 ? "家人将不能再看到共享的东西。每个人都会在自己手机上保留一份现在的东西。"
                 : "你将看不到家里共享的东西，但会在这台手机上保留一份现在的东西；你自己的对话和私密任务不受影响。")
        }
        .alert("没能完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task { await service.sync() }
    }

    private var rulesSummary: String {
        let count = store.rules.count + store.myRules.count
        let quiet = store.me?.quiet.map { "免打扰" + ($0.start == 0 && $0.end == 0 ? "" : " \($0.label)") }
        return [count > 0 ? "\(count) 条" : nil, quiet].compactMap { $0 }.joined(separator: " · ")
    }

    private var syncLine: String {
        guard let date = service.lastSync else { return "打开 App 时会自动和家人同步。" }
        return "\(date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))) 已和家人同步"
    }

    private func invite() {
        Task {
            do {
                let share = try await service.share()
                HouseholdInvite.present(share: share, container: service.cloudContainer)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// The person's initial in their colour.
struct MemberBadge: View {
    let member: HouseholdMember
    var size: CGFloat = 30
    private static let colors: [Color] = [.orange, .blue, .pink, .green, .purple, .teal, .indigo, .mint]

    var body: some View {
        Text(String(member.name.prefix(1)))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(for: member.id), in: Circle())
            .accessibilityHidden(true)
    }

    static func color(for id: UUID) -> Color {
        colors[Int(id.uuid.0) % colors.count]
    }
}

/// The one card after creating or joining: what was shared, what stayed personal, what was merged.
struct HouseholdSummaryCard: View {
    let summary: HouseholdService.Summary
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已经整理好").font(.headline)
                Spacer()
                Button("好", action: onDone).font(.subheadline.weight(.semibold))
            }
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var text: String {
        var parts = ["共享了 \(summary.shared) 样东西"]
        if !summary.personal.isEmpty {
            let names = summary.personal.prefix(3).joined(separator: "、")
            parts.append("\(names)\(summary.personal.count > 3 ? " 等 \(summary.personal.count) 样" : "")留给你自己")
        }
        if summary.merged > 0 { parts.append("和家里重复的 \(summary.merged) 样已经合并") }
        return parts.joined(separator: "；") + "。分错的话点开那样东西改一下，或者跟管家说一声。"
    }
}

/// Name the household and how the family calls you; nothing else is asked.
struct CreateHouseholdSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "我们家"
    @State private var myName = ""
    @State private var error: String?
    private var service: HouseholdService { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("家的名字") { TextField("我们家", text: $name) }
                    .glassRows()
                Section {
                    TextField("例如“老公”“妈妈”", text: $myName)
                } header: { Text("家人怎么称呼你") } footer: {
                    Text("管家会用它分清是谁记的、该提醒谁。建好后先帮你备份，再把手机里的东西分成全家的和你自己的。")
                }
                .glassRows()
                if let error {
                    Section { Text(error).foregroundStyle(.red) }.listRowBackground(Color.clear)
                }
            }
            .glassList()
            .navigationTitle("建立家庭").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if service.busy { ProgressView() } else {
                        Button("建立") {
                            Task {
                                do {
                                    _ = try await service.create(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "我们家" : name,
                                                                 myName: myName.trimmingCharacters(in: .whitespaces).isEmpty ? "我" : myName)
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Shown once on the phone that joined: the household's name, how to be called, what was merged.
struct JoinedHouseholdSheet: View {
    @State private var myName: String = HouseholdStore.shared.me?.name ?? ""
    private var service: HouseholdService { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已加入「\(HouseholdStore.shared.state?.name ?? "我们家")」").font(.title3.bold())
                        Text("家里的东西现在大家一起看、一起记。").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                Section("家人怎么称呼你") { TextField("例如“老婆”“小明”", text: $myName) }
                    .glassRows()
                if let summary = service.summary {
                    Section { HouseholdSummaryCard(summary: summary) { service.summary = nil } }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            .glassList()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { service.rename(me: myName.isEmpty ? "家人" : myName) }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// The system's invite sheet for a household share.
@MainActor
enum HouseholdInvite {
    static func present(share: CKShare, container: CKContainer) {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}
