import SwiftUI

/// Everything the owner configures: who they are, the model account, Jev, memories, chat history.
struct ButlerSettingsView: View {
    @Bindable var chat: ButlerChat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var jevKey = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：我叫安，家里两个人加一只猫；周末去盒马买菜；不吃香菜。",
                              text: $chat.profile, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("关于我和家里")
                } footer: {
                    Text("管家每次对话都会先读这段话。写你希望它一直记得的背景。")
                }

                Section {
                    NavigationLink {
                        MemoriesView(chat: chat)
                    } label: {
                        LabeledContent("管家记住的事", value: "\(chat.tools?.notes.records.count ?? 0) 条")
                    }
                } footer: {
                    Text("对话里你告诉管家的习惯和偏好，确认后保存在这里。")
                }

                Section {
                    if chat.connection.isLoggedIn {
                        Label("已登录 · GPT-6 Sol", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.cobalt)
                        Button("退出登录", role: .destructive) { chat.signOut() }
                    } else if let code = chat.connection.deviceCode {
                        Text("1. 复制登录码")
                        HStack {
                            Text(code.code).font(.title2.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("复制") { UIPasteboard.general.string = code.code }
                        }
                        Button("2. 打开官方页面授权") { openURL(SubscriptionConnection.verificationURL) }
                        HStack { ProgressView(); Text("授权后回到这里，会自动完成登录") }
                        Button("取消") { chat.connection.cancelLogin() }
                    } else {
                        Button(chat.connection.signingIn ? "正在获取登录码…" : "用 Codex 订阅登录") {
                            Task { await chat.connection.beginLogin() }
                        }
                        .disabled(chat.connection.signingIn)
                    }
                    if let error = chat.connection.error { Text(error).foregroundStyle(Theme.vermilion) }
                } header: {
                    Text("对话模型")
                } footer: {
                    Text("你说的话、拍的照片和相关的库存、笔记会发给模型来理解；库存和笔记保存在这台 iPhone。")
                }

                Section {
                    if chat.jev.isConfigured {
                        Label("已接入 Jev · \(JevClient.model)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.cobalt)
                        LabeledContent("本次打开后调用", value: "\(chat.jev.callsThisSession) 次")
                        Button("移除密钥", role: .destructive) { chat.jev.removeKey() }
                    } else {
                        SecureField("粘贴 Jev API 密钥", text: $jevKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("保存") {
                            try? chat.jev.saveKey(jevKey)
                            jevKey = ""
                        }
                        .disabled(jevKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Jev 条件判断")
                } footer: {
                    Text("接入后，管家每次查家里的东西、每次提出修改，都会先请 Jev 核对：说的是哪一件、数字是剩余还是用掉、是新买还是纠正、日期是不是你说的。不填也能完整使用，只是少这一道核对。密钥保存在系统钥匙串。")
                }

                Section {
                    Button("清空对话记录", role: .destructive) { confirmClear = true }
                        .disabled(chat.turns.isEmpty || chat.working)
                } footer: {
                    Text("只清空聊天内容和聊天里的照片，不影响库存和管家记住的事。")
                }

                Section {
                    LabeledContent("版本", value: Self.version)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: chat.connection.deviceCode?.id) { await chat.connection.awaitApproval() }
            .onChange(of: chat.connection.isLoggedIn) { _, loggedIn in
                if loggedIn { chat.didSignIn() }
            }
            .onDisappear { chat.connection.cancelLogin() }
            .confirmationDialog("清空全部对话记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { chat.clearHistory() }
            }
        }
        .tint(Theme.cobalt)
        .presentationDetents([.large])
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}

private struct MemoriesView: View {
    let chat: ButlerChat

    var body: some View {
        List {
            let records = chat.tools?.notes.records ?? []
            if records.isEmpty {
                Text("还没有记住的事。在对话里告诉管家你的习惯，比如“盒马的麻薯我一般买小盒，放冰箱上层”。")
                    .foregroundStyle(Theme.muted)
            }
            ForEach(records) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title).font(Theme.display(16, weight: .semibold))
                    Text(note.text).font(Theme.body(14)).foregroundStyle(Theme.inkSoft)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                for index in offsets { try? chat.tools?.notes.delete(records[index].id) }
            }
        }
        .navigationTitle("管家记住的事").navigationBarTitleDisplayMode(.inline)
    }
}
