import SwiftUI
import UniformTypeIdentifiers

/// An explicit owner gesture opens Apple's directory picker; model output cannot select a path.
struct FolderAccessPrompt: View {
    @Bindable var chat: ButlerChat
    let hasOtherWork: Bool
    @State private var choosing = false
    @State private var request: UUID?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if chat.tools?.folderSelectionRequest != nil {
                Text("仅授权你选中的文件夹及子目录；不会自动读取正文。可随时在对话中撤销授权。")
                    .font(.subheadline)
                HStack {
                    Button("选择文件夹", systemImage: "folder") {
                        request = chat.tools?.folderSelectionRequest
                        choosing = true
                    }
                    .frame(minHeight: 44)
                    Button("取消选择") {
                        if let id = chat.tools?.folderSelectionRequest { chat.cancelFolderSelection(id) }
                        request = nil
                        notice = "已取消，未增加文件夹授权。"
                    }
                    .frame(minHeight: 44)
                }
                .disabled(chat.working || hasOtherWork)
            }
            if let notice { Text(notice).font(.footnote).textSelection(.enabled) }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard let request else { return }
            defer { self.request = nil }
            do {
                let urls = try result.get()
                guard !hasOtherWork, let url = urls.first else { throw FolderFailure("未选择文件夹或另一操作尚未结束。") }
                try chat.acceptFolderSelection(url, request: request)
                notice = "已保存文件夹授权，尚未查找或写入文件。"
            } catch {
                chat.cancelFolderSelection(request)
                notice = "本次未增加授权：\(error.localizedDescription)"
            }
        }
        .onDisappear {
            if let request { chat.cancelFolderSelection(request) }
            request = nil
        }
    }
}
