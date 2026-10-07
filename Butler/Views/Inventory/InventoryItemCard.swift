import ImageIO
import SwiftUI

/// Quiet, equal-width tiles keep the object recognizable even in a large collection.
struct InventoryItemCard: View {
    let lot: LotFacts
    var listLayout = false
    @Environment(\.colorScheme) private var scheme

    private var tint: Color {
        switch lot.category {
        case .food: Color(light: 0x5A7351, dark: 0xA2BC95)
        case .medicine: Color(light: 0xAB626D, dark: 0xDEA0AA)
        case .household: Color(light: 0x507B93, dark: 0x91BBD1)
        case .clothing: Color(light: 0x857094, dark: 0xBCA7CC)
        case .electronics: Color(light: 0x61728A, dark: 0xA1B3CD)
        case .tools: Color(light: 0x9B7849, dark: 0xD2AF7C)
        case .other: Color(light: 0x5D827D, dark: 0xA4C5C0)
        }
    }
    private var statusColor: Color {
        if lot.isRunningLow || (!lot.quantityOnly && (lot.daysLeft ?? 1) < 0) { return .red }
        if !lot.quantityOnly, let days = lot.daysLeft, days <= 3 { return .orange }
        return .secondary
    }
    private var subtitle: String {
        [lot.category.title, lot.storageLocation?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if listLayout {
                HStack(spacing: 12) {
                    artwork.frame(width: 44, height: 44)
                    details
                    Spacer(minLength: 4)
                    quantity
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        artwork.frame(width: 40, height: 40)
                        Spacer(minLength: 4)
                        quantity
                    }
                    details
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(InventoryCardSurface())
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开物品详情")
    }

    private var artwork: some View {
        InventoryArtwork(photo: lot.profile?.photo, symbol: InventoryCatalog.symbol(for: lot), tint: tint)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint.opacity(scheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var quantity: some View {
        Text("\(lot.quantity)\(lot.unit)")
            .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lot.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let status = InventoryCatalog.status(for: lot) {
                Text(status).font(.caption).foregroundStyle(statusColor).lineLimit(2)
            }
        }
    }
}

/// Light cards need a tonal boundary against the near-white page; white-on-white
/// glass highlights alone disappear. Keep the established dark treatment intact.
private struct InventoryCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if scheme == .dark {
            content.glassCard(radius: 20)
        } else {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            content
                .background(LinearGradient(colors: [Color(hex: 0xEDF0F4), Color(hex: 0xE4E8EE)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.90), in: shape)
                .overlay(shape.strokeBorder(Color(hex: 0x94A0B0).opacity(0.28), lineWidth: 0.75))
                .shadow(color: Color.black.opacity(0.045), radius: 10, y: 4)
        }
    }
}

private struct InventoryArtwork: View {
    let photo: Data?
    let symbol: String
    let tint: Color
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: symbol)
                    .resizable().scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .shadow(color: tint.opacity(0.14), radius: 8, y: 6)
            }
        }
        .accessibilityHidden(true)
        .task(id: photo) {
            thumbnail = nil
            guard let photo else { return }
            // Downsample off the UI thread; a grid must not decode full-size camera photos as it scrolls.
            let image = await Task.detached(priority: .utility) { Self.downsample(photo) }.value
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }

    nonisolated private static func downsample(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
