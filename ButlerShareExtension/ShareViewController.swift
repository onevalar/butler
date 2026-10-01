import UIKit
import Social
import UniformTypeIdentifiers

/// Standard system compose sheet; never launches the app or accesses its database/network.
final class ShareViewController: SLComposeServiceViewController {
    private let receiptID = UUID()
    private var saving = false
    private var cancelled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "保存到小当家"
        placeholder = "可补充用途；保存后请打开小当家核对，不会自动入库。"
    }

    override func isContentValid() -> Bool {
        !saving && (contentText?.count ?? 0) <= ShareInbox.maxTextCharacters
    }

    override func didSelectCancel() {
        cancelled = true
        super.didSelectCancel()
    }

    override func didSelectPost() {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            do {
                let inbox = try ShareInbox.onDevice()
                try inbox.begin(id: receiptID)
                do {
                    var text = [contentText ?? ""]
                    var files: [ShareInbox.Attachment] = []
                    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
                    let providers = items.flatMap { $0.attachments ?? [] }
                    guard providers.count <= ShareInbox.maxFiles else {
                        throw ShareInbox.Failure("每次最多分享8项，请分批分享。")
                    }
                    for item in items {
                        if let original = item.attributedContentText?.string, !text.contains(original) { text.append(original) }
                    }
                    for provider in providers {
                        guard !cancelled else { throw CancellationError() }
                        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
                        let fileType = types.first { $0.conforms(to: .image) || $0.conforms(to: .pdf) }
                            ?? types.first { $0.conforms(to: .data) && !$0.conforms(to: .plainText) }
                        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            files.append(try await copyFileURL(provider, inbox: inbox, existing: files))
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                            let value = try await loadItem(provider, type: UTType.url.identifier)
                            guard let url = value as? URL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                                throw ShareInbox.Failure("仅支持网页链接，请将本地文件作为附件分享。")
                            }
                            if !text.contains(url.absoluteString) { text.append(url.absoluteString) }
                        } else if let fileType {
                            files.append(try await copyRepresentation(provider, type: fileType.identifier, inbox: inbox, existing: files))
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                            let value = try await loadItem(provider, type: UTType.plainText.identifier)
                            guard let string = value as? String else { throw ShareInbox.Failure("无法读取分享文字") }
                            if !text.contains(string) { text.append(string) }
                        } else {
                            throw ShareInbox.Failure("来源 App 未提供可读取的文字、链接或文件，请换一种分享方式。")
                        }
                    }
                    guard !cancelled else { throw CancellationError() }
                    _ = try inbox.publish(id: receiptID, text: text.filter { !$0.isEmpty }.joined(separator: "\n\n"), attachments: files)
                    extensionContext?.completeRequest(returningItems: nil)
                } catch {
                    inbox.cancel(id: receiptID)
                    throw error
                }
            } catch {
                guard !cancelled else { return }
                let alert = UIAlertController(title: "没有保存这次分享", message: error.localizedDescription + "\n请关闭后重试；原内容仍在来源 App 中。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "关闭", style: .default) { [weak self] _ in
                    self?.extensionContext?.cancelRequest(withError: error)
                })
                present(alert, animated: true)
            }
        }
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: ShareInbox.Failure("来源内容暂时不可用")) }
            }
        }
    }

    private func copyFileURL(_ provider: NSItemProvider, inbox: ShareInbox,
                             existing: [ShareInbox.Attachment]) async throws -> ShareInbox.Attachment {
        let id = receiptID
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                do {
                    if let error { throw error }
                    guard let url = value as? URL else { throw ShareInbox.Failure("无法读取文件地址") }
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
                    continuation.resume(returning: try inbox.copyFile(url, name: url.lastPathComponent,
                        type: type, id: id, existing: existing))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func copyRepresentation(_ provider: NSItemProvider, type: String, inbox: ShareInbox,
                                    existing: [ShareInbox.Attachment]) async throws -> ShareInbox.Attachment {
        let id = receiptID
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw ShareInbox.Failure("附件暂时无法下载，请确认网络后重试。") }
                    // Copy now, not after resuming: the provider deletes this URL on callback return.
                    continuation.resume(returning: try inbox.copyFile(url, name: name ?? url.lastPathComponent,
                        type: type, id: id, existing: existing))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
