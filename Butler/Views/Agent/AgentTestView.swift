import SwiftUI

struct AgentTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var chat = OnDeviceChat()
    @State private var account = false
    @State private var memories = false
    @State private var search = ""
    @FocusState private var composing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Label(chat.fixture ? "界面演示 · 未连接模型" : "本机记忆 · 仅虚构资料试用", systemImage: "iphone")
                    Spacer()
                }.font(.footnote).foregroundStyle(Theme.cobalt).padding(14).background(Theme.surface)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if chat.turns.isEmpty { welcome }
                            ForEach(chat.turns) { turn in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(turn.question).padding(14).frame(maxWidth: .infinity, alignment: .trailing)
                                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                                    if !turn.answer.isEmpty && !turn.failed { Text(turn.answer).textSelection(.enabled) }
                                }
                            }
                            if chat.working {
                                HStack { ProgressView(); Text("正在理解，按需查询本机记忆…") }
                                    .font(.callout).foregroundStyle(Theme.inkSoft)
                            }
                            if let preview = chat.agent?.memory.preview, !chat.working { previewCard(preview) }
                            if let notice = chat.notice {
                                Label(notice, systemImage: "checkmark.circle").foregroundStyle(Theme.cobalt)
                                    .accessibilityIdentifier("agent.notice")
                            }
                            if let error = chat.error {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .foregroundStyle(Theme.vermilion).accessibilityIdentifier("agent.error")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.turns.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: chat.working) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                composer
            }
            .background(Theme.ground).foregroundStyle(Theme.ink)
            .navigationTitle("管家").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { chat.stop(); dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { memories = true; composing = false } label: { Image(systemName: "tray.full") }
                        .accessibilityLabel("本机记忆").accessibilityIdentifier("agent.records")
                    Button { account = true; composing = false } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel("订阅登录").accessibilityIdentifier("agent.settings").disabled(chat.working)
                }
            }
            .sheet(isPresented: $account, onDismiss: { chat.connection.cancelLogin() }) { accountView }
            .sheet(isPresented: $memories) { memoryView }
            .onDisappear { chat.stop() }
        }.tint(Theme.cobalt)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("生活里的事，\n直接告诉我。").font(Theme.display(30))
            Text("买了什么、放在哪里，或想记住的一件事。\n不必先分类，我会整理成你能核对的内容。")
                .foregroundStyle(Theme.inkSoft)
            if !chat.available {
                Button("登录订阅，开始对话") { account = true }
                    .buttonStyle(.borderedProminent).tint(Theme.cobaltFill).foregroundStyle(.white)
                    .accessibilityIdentifier("agent.login")
            } else {
                Text("例如：盒马买了6个麻薯，放冰箱上层。")
                    .font(.callout).foregroundStyle(Theme.cobalt)
            }
            Text("记忆保存在本机。每次重新打开会开始新对话，已保存的内容仍可查询。当前先支持文字。")
                .font(.footnote).foregroundStyle(Theme.muted)
        }.padding(.vertical, 24)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.available { Text("登录后才能请模型整理；本机记忆仍可查看。").font(.footnote).foregroundStyle(Theme.muted) }
            if chat.draft.count > 8000 { Text("这段内容较长，请分成几条发送。").font(.footnote).foregroundStyle(Theme.vermilion) }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("告诉管家…", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...5).focused($composing).disabled(chat.working)
                    .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("给管家的消息").accessibilityIdentifier("agent.input")
                if chat.working {
                    Button { chat.stop() } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("停止回复").accessibilityIdentifier("agent.stop")
                } else {
                    Button { composing = false; chat.send() } label: {
                        Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44)
                            .foregroundStyle(.white).background(Theme.cobaltFill, in: Circle())
                    }.disabled(!chat.canSend).opacity(chat.canSend ? 1 : 0.4)
                        .accessibilityLabel("发送").accessibilityIdentifier("agent.send")
                }
            }
        }.padding(16)
    }

    private func memoryContent(_ memory: LocalMemory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(memory.title).font(.headline)
            if let quantity = memory.quantity { Text("数量：\(quantity)").monospacedDigit() }
            Text(memory.text).foregroundStyle(Theme.inkSoft)
        }
    }

    private func previewCard(_ preview: LocalMemoryPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("核对一下 · 尚未保存", systemImage: "checkmark.square").font(.headline)
            if let before = preview.before {
                Text("修改前").font(.caption).foregroundStyle(Theme.muted)
                memoryContent(before)
                Divider()
            }
            Text(preview.before == nil ? "新增记忆" : "修改后").font(.caption).foregroundStyle(Theme.muted)
            memoryContent(preview.after)
            Text("请核对对象、数量和日期。也可以继续说一句话纠正，旧预览会被替换。")
                .font(.footnote).foregroundStyle(Theme.muted)
            HStack {
                Button("取消") { chat.discard() }.buttonStyle(.bordered)
                    .accessibilityIdentifier("agent.discard")
                Spacer()
                Button("确认保存到本机") { chat.confirm() }.buttonStyle(.borderedProminent)
                    .tint(Theme.cobaltFill).foregroundStyle(.white).accessibilityIdentifier("agent.confirm")
            }
        }.padding(18).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var accountView: some View {
        NavigationStack {
            Form {
                Section("云端模型，本机执行") {
                    Text("GPT-6 Sol · Medium")
                    Text("输入内容和查询到的相关记忆会发送给 OpenAI。记忆文件保存在这台 iPhone，不需要填写服务器地址。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    if chat.fixture {
                        Text("当前为界面测试替身，没有登录或调用真实模型。")
                    } else if chat.connection.isLoggedIn {
                        Label("已登录订阅", systemImage: "checkmark.circle")
                        Button("退出登录", role: .destructive) { chat.signOut() }
                        Text("只移除这台设备的登录信息，不删除本机记忆。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let code = chat.connection.deviceCode {
                        Text("1. 复制这次登录码")
                        HStack {
                            Text(code.code).font(.title2.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("复制") { UIPasteboard.general.string = code.code }
                        }
                        Button("2. 打开官方页面授权") { openURL(SubscriptionConnection.verificationURL) }
                        Text("仅在你刚打开的官方页面输入此码，不要发给别人。授权后返回这里，App 会继续登录。")
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack { ProgressView(); Text("等待你完成授权…") }
                        Button("取消这次登录") { chat.connection.cancelLogin() }
                    } else {
                        Button(chat.connection.signingIn ? "正在获取登录码…" : "用 Codex 订阅登录") {
                            Task { await chat.connection.beginLogin() }
                        }.disabled(chat.connection.signingIn).accessibilityIdentifier("agent.authorize")
                        Text("在官方页面完成登录，Butler 不收集账号密码。若账号尚未启用设备码登录，需要先在官方设置中开启。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = chat.connection.error { Text(error).foregroundStyle(Theme.vermilion) }
                }
                Section { Text("当前为虚构资料试用，不会读取原库存。Jev、语音、照片和提醒尚未接入这个入口。") }
            }
            .navigationTitle("订阅登录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { account = false } } }
            .task(id: chat.connection.deviceCode?.id) { await chat.connection.awaitApproval() }
            .onChange(of: chat.connection.isLoggedIn) { _, loggedIn in
                if loggedIn { chat.didSignIn(); account = false }
            }
        }
    }

    private var memoryView: some View {
        NavigationStack {
            List {
                Section {
                    Text("保存在这台 iPhone · 不联网也能查看").font(.footnote).foregroundStyle(.secondary)
                }
                let records = chat.agent?.memory.records ?? []
                let matches = records.filter { search.isEmpty || ($0.title + $0.text).localizedStandardContains(search) }
                if matches.isEmpty {
                    Text(search.isEmpty ? "还没有已保存的记忆。对话里确认后会出现在这里。" : "没有找到相符的记忆，试试其他关键词。")
                        .foregroundStyle(.secondary)
                }
                ForEach(matches) { memoryContent($0).padding(.vertical, 6) }
                if chat.agent == nil { Text("记忆读取失败，原文件未修改。").foregroundStyle(Theme.vermilion) }
            }
            .searchable(text: $search, prompt: "搜索本机记忆")
            .navigationTitle("本机记忆")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { memories = false } } }
        }
    }
}
