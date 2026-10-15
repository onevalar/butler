import CloudKit
import SwiftUI
import UIKit

/// 管家与设置 › 家庭: create the household, invite the family, see who is in it, leave.
struct HouseholdSettingsPage: View {
    @State private var creating = false
    @State private var preparingInvite = false
    @State private var copyingLink = false
    @State private var copiedLink = false
    @State private var confirmLeave = false
    @State private var error: String?
    @State private var recovery: HouseholdService.Recovery?
    @State private var recovering = false
    @State private var enteringInvite = false
    @State private var invitationText = ""
    private var service: HouseholdService { .shared }
    private var store: HouseholdStore { .shared }

    var body: some View {
        Form {
            if let state = store.state {
                if service.needsSyncRecovery {
                    Section {
                        Text("恢复后，会将这台手机当前的共享物品和日程与家庭合并同步。个人资料仍只属于你。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(recovering ? "正在准备…" : "恢复家庭同步") {
                            recovering = true
                            Task {
                                defer { recovering = false }
                                do { recovery = try await service.recoveryPreview() }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(recovering || service.busy)
                    }.glassRows()
                }
                if let summary = service.summary {
                    Section { HouseholdSummaryCard(summary: summary) { service.summary = nil } }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    if store.isOwner {
                        NavigationLink { HouseholdIdentityEditor(memberID: nil) } label: {
                            LabeledContent("家庭名称", value: state.name)
                        }
                    } else {
                        LabeledContent("家庭名称", value: state.name)
                    }
                } footer: {
                    Text(store.isOwner ? "全家看到同一个家庭名称，点击即可修改。" : "家庭名称由创建者修改。")
                }
                .glassRows()
                Section {
                    ForEach(store.members) { member in
                        NavigationLink { HouseholdIdentityEditor(memberID: member.id) } label: {
                            HStack(spacing: 12) {
                                MemberBadge(member: member)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.displayName(member)).foregroundStyle(.primary)
                                    Text(member.id == state.me ? "我 · 编辑显示名字" :
                                         store.aliases[member.id] == nil ? "设置我对 TA 的称呼" : "显示名字：" + member.name)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if member.isOwner { Text("创建者").font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if store.isOwner {
                        Button { invite() } label: {
                            HStack {
                                Label(preparingInvite ? "正在准备邀请…" : "邀请家人", systemImage: "person.badge.plus")
                                if preparingInvite { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(preparingInvite || copyingLink)
                        Button {
                            copyFamilyLink()
                        } label: {
                            HStack {
                                Label(copyingLink ? "正在生成邀请…" : "复制邀请链接", systemImage: "link")
                                if copyingLink { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(preparingInvite || copyingLink)
                    }
                } header: {
                    Text("家庭成员")
                } footer: {
                    Text(syncLine)
                    if store.isOwner {
                        Text("家人先更新小当家，再打开邀请加入。每条链接供一位家人使用；邀请下一位时再生成一条。")
                    }
                }
                .glassRows()

                Section {
                    if store.isOwner {
                        Button { invite(purpose: .manage) } label: {
                            Label("管理家庭共享", systemImage: "person.2.badge.gearshape")
                        }
                        .disabled(preparingInvite || copyingLink)
                    }
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
                    Button { enteringInvite = true } label: { Label("通过邀请链接加入", systemImage: "link") }
                }
                .glassRows()
            }
        }
        .glassList()
        .compactTitle("家庭") { EmptyView() }
        .sheet(isPresented: $creating) { CreateHouseholdSheet() }
        .alert("邀请链接已复制", isPresented: $copiedLink) {
            Button("好", role: .cancel) {}
        } message: {
            Text("发给一位已更新小当家的家人。链接会直接打开 App；如果聊天软件不支持打开，可在小当家“家庭 → 通过邀请链接加入”中粘贴。邀请其他家人时，请再复制一条新链接。")
        }
        .alert("加入家庭", isPresented: $enteringInvite) {
            TextField("粘贴家人发来的邀请链接", text: $invitationText)
            Button("加入") {
                guard let url = URL(string: invitationText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    error = "邀请链接不完整，请重新粘贴。"; return
                }
                Task { await service.openInvitation(url) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("如果浏览器没有自动打开小当家，可以在这里粘贴邀请链接。") }
        .alert("恢复家庭同步？", isPresented: Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } })) {
            Button("恢复并同步") {
                guard let preview = recovery else { return }
                recovery = nil
                Task {
                    do { try await service.recoverSync(preview) }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { recovery = nil }
        } message: {
            Text("会先备份本机资料，再将当前共享物品和日程合并到家庭。若此前清理过云端，本机仍保留的共享内容可能重新出现。")
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
        if let issue = service.syncIssue { return issue }
        if store.joining { return "正在同步家庭资料，完成后会整理本机物品。" }
        guard let date = service.lastSync else { return "打开 App 时会自动和家人同步。" }
        return "\(date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))) 已和家人同步"
    }

    private func copyFamilyLink() {
        guard !preparingInvite, !copyingLink else { return }
        copyingLink = true
        Task {
            defer { copyingLink = false }
            do {
                let invitation = try await service.invitationURL()
                let link = try HouseholdShareLink.applicationURL(for: invitation)
                UIPasteboard.general.setItems([["public.url": link.absoluteString,
                                                "public.utf8-plain-text": link.absoluteString]],
                                              options: [.localOnly: true])
                copiedLink = true
                ChatDiagnostics.log("household single-use invitation copied locally")
            } catch { self.error = HouseholdSharePreparation.message(for: error) }
        }
    }

    private func invite(purpose: HouseholdInvite.Purpose = .invite) {
        guard !preparingInvite, !copyingLink else { return }
        preparingInvite = true
        Task {
            defer { preparingInvite = false }
            do {
                if purpose == .invite {
                    let link = try await service.invitationURL()
                    try HouseholdInvite.presentInvitation(url: link, title: store.state?.name ?? "我们家")
                    return
                }
                let share = try await service.share()
                try HouseholdInvite.presentManagement(share: share, container: service.cloudContainer) { message in
                    self.error = message
                }
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
                Section("家庭名称") { TextField("我们家", text: $name) }
                    .glassRows()
                Section {
                    TextField("例如“小安”", text: $myName)
                } header: { Text("我的显示名字") } footer: {
                    Text("全家都会看到这个名字，之后可以修改。对家人的“妈妈”“老公”等称呼，可加入后分别设置。")
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
                                                                 myName: myName)
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                        .disabled(myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || myName.count > 40 || name.count > 40)
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
    @State private var nameError: String?
    private var service: HouseholdService { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(service.lastSync == nil ? "正在加入" : "已加入")「\(HouseholdStore.shared.state?.name ?? "我们家")」").font(.title3.bold())
                        if let issue = service.syncIssue {
                            Text(issue).font(.subheadline).foregroundStyle(.secondary)
                            Button("重新同步") { Task { await service.sync() } }
                        } else if service.lastSync == nil {
                            ProgressView("正在同步家庭资料…")
                        } else {
                            Text("家庭资料已同步，可以一起查看和记录了。").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                Section { TextField("例如“小明”", text: $myName) } header: { Text("我的显示名字") } footer: { Text("全家看到的名字，可随时在家庭成员里修改。关系称呼由每位家人自己设置。") }
                    .glassRows()
                if let nameError { Text(nameError).foregroundStyle(.red) }
                if let summary = service.summary {
                    Section { HouseholdSummaryCard(summary: summary) { service.summary = nil } }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            .glassList()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(service.lastSync == nil ? "稍后继续" : "完成") {
                        do { try service.rename(me: myName) } catch { nameError = error.localizedDescription }
                    }.disabled(myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || myName.count > 40)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// Shared identity and personal relationships have different ownership and storage.
private struct HouseholdIdentityEditor: View {
    let memberID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var saving = false
    @State private var error: String?
    private var store: HouseholdStore { .shared }
    private var isMe: Bool { memberID != nil && memberID == store.state?.me }
    private var title: String { memberID == nil ? "家庭名称" : isMe ? "我的显示名字" : "我对 TA 的称呼" }

    var body: some View {
        Form {
            if let memberID, let member = store.member(memberID), !isMe {
                Section {
                    LabeledContent("显示名字", value: member.name)
                } footer: { Text("这是 TA 设置的名字，全家可见。") }
                .glassRows()
            }
            Section {
                TextField(memberID == nil ? "我们家" : isMe ? "例如“小安”" : "例如“妈妈”“老公”", text: $value)
                    .accessibilityLabel(title)
            } header: { Text(title) } footer: {
                Text(memberID == nil ? "修改后，全家同步时会看到新名称。需要连接 iCloud 才能保存。" :
                     isMe ? "全家都会看到这个名字。改名不会改变已有物品、任务和负责人；联网后自动同步。" :
                     "仅在这台设备上显示和使用这个称呼，管家会据此理解你说的是谁，不改变其他家人的称呼。留空恢复 TA 的显示名字。")
            }
            .glassRows()
            if let error { Section { Text(error).foregroundStyle(.red) }.listRowBackground(Color.clear) }
        }
        .glassList()
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("保存") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                if let memberID {
                                    if isMe { try HouseholdService.shared.rename(me: value) }
                                    else { try store.setAlias(value, for: memberID) }
                                } else { try await HouseholdService.shared.renameHousehold(value) }
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(value.count > (memberID != nil && !isMe ? 20 : 40) ||
                              ((memberID == nil || isMe) && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .task {
            if let memberID { value = isMe ? store.member(memberID)?.name ?? "" : store.aliases[memberID] ?? "" }
            else { value = store.state?.name ?? "" }
        }
    }
}
