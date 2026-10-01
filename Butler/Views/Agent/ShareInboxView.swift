import SwiftUI
import QuickLook

/// An inline part of the existing conversation, not a separate management screen.
struct ShareInboxView: View {
    @Bindable var chat: ButlerChat
    var hasOtherWork: Bool
    var refreshID: UUID
    @Environment(\.scenePhase) private var scenePhase
    @State private var records: [ShareInbox.Record] = []
    @State private var error: String?
    @State private var preview: URL?
    @State private var expanded = true
    @State private var importing: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !records.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    Text("内容只保存在本机。加入草稿、核对并发送后，才会交给当前模型；不会直接修改任务或库存。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(records.reversed()) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            if !record.text.isEmpty {
                                DisclosureGroup(String(record.text.prefix(60))) {
                                    Text(record.text).textSelection(.enabled)
                                }
                            }
                            ForEach(record.attachments) { file in
                                Button {
                                    do { preview = try ShareContentReader.preview(file, record: record, inbox: ShareInbox.onDevice()) }
                                    catch { self.error = error.localizedDescription }
                                } label: { Label("查看原件：\(file.name)", systemImage: "doc") }
                                .frame(minHeight: 44)
                            }
                            if chat.receivedShareIDs.contains(record.id) {
                                Label("已加入过草稿 · 原件保留", systemImage: "checkmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("加入草稿，继续聊") {
                                    importing = record.id
                                }
                                .frame(minHeight: 44)
                                .disabled(chat.working || hasOtherWork || importing != nil)
                                if importing == record.id { ProgressView("正在读取资料…") }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } label: {
                    let pending = records.filter { !chat.receivedShareIDs.contains($0.id) }.count
                    Label("分享资料 · \(pending) 条待处理", systemImage: "tray")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("重新读取分享") { reload() }.frame(minHeight: 44)
            }
        }
        .quickLookPreview($preview)
        .task(id: refreshID) { reload() }
        .task(id: importing) {
            guard let id = importing, let record = records.first(where: { $0.id == id }) else { return }
            defer { importing = nil }
            do {
                let inbox = try ShareInbox.onDevice()
                let reader = Task.detached(priority: .userInitiated) {
                    try ShareContentReader.read(record, inbox: inbox)
                }
                let content = try await withTaskCancellationHandler {
                    try await reader.value
                } onCancel: {
                    reader.cancel()
                }
                try Task.checkCancellation()
                guard !hasOtherWork else { throw ShareInbox.Failure("请等正在运行的对话结束后再试。") }
                try chat.receiveShare(record, content: content)
                error = nil
            } catch is CancellationError {
                // Closing the conversation cancels insertion; the original remains in the inbox.
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private func reload() {
        do {
            let listing = try ShareInbox.onDevice().list()
            records = listing.records
            error = listing.unreadableCount > 0 ? "\(listing.unreadableCount)条分享暂时无法读取，原记录未删除或覆盖。请从来源 App 重新分享。" : nil
        } catch { self.error = error.localizedDescription }
    }
}
