import MarkdownUI
import SwiftUI

/// Shared by live replies and related history; stored/model-facing text stays unchanged.
struct ChatMarkdownText: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(Self.theme)
            .markdownImageProvider(ReplyImageProvider())
            .markdownInlineImageProvider(ReplyInlineImageProvider())
            .environment(\.openURL, OpenURLAction { url in
                // A model-generated link must not launch arbitrary app/file schemes.
                switch url.scheme?.lowercased() {
                case "https", "http", "mailto": return .systemAction
                default: return .discarded
                }
            })
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private static let theme = MarkdownUI.Theme.basic
        .heading1 { heading($0, size: 1.25) }
        .heading2 { heading($0, size: 1.18) }
        .heading3 { heading($0, size: 1.10) }
        .heading4 { heading($0, size: 1) }
        .heading5 { heading($0, size: 1) }
        .heading6 { heading($0, size: 1) }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: false)
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.94))
                    }
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .markdownMargin(top: .zero, bottom: .em(0.75))
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label.fixedSize(horizontal: true, vertical: false)
            }
            .markdownMargin(top: .zero, bottom: .em(0.75))
        }

    private static func heading(_ configuration: BlockConfiguration, size: CGFloat) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(size))
            }
            .markdownMargin(top: .em(0.75), bottom: .em(0.35))
    }
}

// Do not silently contact a model-supplied image host when displaying history.
// Block images remain available through an explicit tap; inline images keep their label.
private struct ReplyImageProvider: ImageProvider {
    nonisolated func makeImage(url: URL?) -> some View {
        ReplyImageLink(url: url)
    }
}

private struct ReplyImageLink: View {
    let url: URL?

    nonisolated init(url: URL?) {
        self.url = url
    }

    var body: some View {
        if let url {
            Link(destination: url) { Label("查看图片", systemImage: "photo") }
        } else {
            Label("图片地址不可用", systemImage: "photo")
        }
    }
}

private struct ReplyInlineImageProvider: InlineImageProvider {
    nonisolated func image(with url: URL, label: String) async throws -> Image {
        Image(systemName: "photo")
    }
}
