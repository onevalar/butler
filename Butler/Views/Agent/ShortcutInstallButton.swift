import SwiftUI
import UIKit

/// Hand the signed document to its registered importer. Quick Look only previews it;
/// its process cannot resolve all App Intent actions and cannot add the shortcut.
struct ShortcutInstallButton: UIViewRepresentable {
    let title: String
    let url: URL
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(context.coordinator, action: #selector(Coordinator.install(_:)), for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.setTitle(title, for: .normal)
        context.coordinator.url = url
        context.coordinator.onFailure = onFailure
    }

    @MainActor final class Coordinator: NSObject, UIDocumentInteractionControllerDelegate {
        var url: URL?
        var onFailure: ((String) -> Void)?
        private var document: UIDocumentInteractionController?
        nonisolated deinit {}

        @objc func install(_ button: UIButton) {
            guard document == nil, let url else { return }
            do {
                // Give the receiving app a stable, readable copy, outside the code-signed bundle.
                let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
                    .appendingPathComponent("ShortcutInstallation", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(url.lastPathComponent)
                try Data(contentsOf: url).write(to: destination, options: .atomic)
                let controller = UIDocumentInteractionController(url: destination)
                controller.uti = "com.apple.shortcut"
                controller.delegate = self
                document = controller
                guard controller.presentOpenInMenu(from: button.bounds, in: button, animated: true) else {
                    document = nil
                    onFailure?("没有找到可导入模板的应用。请确认苹果「快捷指令」App 已安装，再回到这里重试。")
                    return
                }
            } catch {
                document = nil
                onFailure?("模板无法读取或保存，请重试。没有添加或运行任何快捷指令。")
            }
        }

        func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
            if document === controller { document = nil }
        }
    }
}
