import SwiftUI

/// Shown instead of the app when the on-device store cannot be opened. Nothing is deleted or
/// rebuilt here: the original files stay where they are, and retrying only tries to open them again.
struct StoreUnavailableView: View {
    let detail: String
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView {
                    Label("资料暂时无法打开", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("小当家没能打开手机上的资料库。原文件仍保留在原位，没有删除或覆盖。\n\n可以稍后重试，或先重启手机、确认存储空间充足。如果一直失败，请先不要删除小当家（删除 App 会一并删除资料），把下面的信息发给开发者。")
                } actions: {
                    Button(action: onRetry) {
                        Text("重试").frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                        .accessibilityLabel("错误信息：\(detail)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 40)
        }
    }
}

#Preview {
    StoreUnavailableView(detail: "SwiftDataError(_error: SwiftData.SwiftDataError._Error.loadIssueModelContainer)", onRetry: {})
}
