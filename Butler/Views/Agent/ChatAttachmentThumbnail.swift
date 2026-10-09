import ImageIO
import SwiftUI

/// History scrolling must not synchronously decode full-resolution screenshots.
struct ChatAttachmentThumbnail: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.08)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .clipped()
        .task(id: url) {
            let sourceURL = url
            let image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 330,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return Optional<UIImage>.none }
                return UIImage(cgImage: image)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}
