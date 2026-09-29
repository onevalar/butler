import SwiftUI
import SwiftData

/// A list the butler pulled together ("修自行车用得上", "冷藏里"). Rows open the thing; × takes a line off
/// this list only (the thing stays at home). Stored lists reference real IDs; live records fill in the rest.
struct InventoryResultView: View {
    let collection: ItemCollection
    let onOpen: (UUID) -> Void
    var onRemove: ((UUID) -> Void)? = nil
    @Query private var lots: [InventoryLot]
    @Query private var products: [CatalogProduct]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(collection.title) · \(collection.items.count) 样")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            if collection.items.isEmpty {
                Text("清单里已经没有东西了").font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            ForEach(Array(collection.items.enumerated()), id: \.element.id) { index, entry in
                row(entry)
                if index < collection.items.count - 1 { RowDivider(inset: 68) }
            }
        }
        .padding(.bottom, 4)
        .glassCard(radius: 22)
        .padding(.trailing, 8)
        .animation(.snappy, value: collection.items.map(\.id))
    }

    private func row(_ entry: ItemCollection.Entry) -> some View {
        let lot = lots.first { $0.id == entry.id }
        let facts = lot.map { lot in LotFacts(lot: lot, product: products.first { $0.id == lot.productID }) }
        return HStack(spacing: 10) {
            Button { onOpen(entry.id) } label: {
                HStack(spacing: 12) {
                    ItemPhoto(profile: facts.map { $0.profile ?? ItemProfile(category: $0.category) }, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text(subtitle(facts)).font(.subheadline).foregroundStyle(color(facts))
                            .lineLimit(1)
                        if !entry.reason.isEmpty {
                            Text(entry.reason).font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(lot == nil)
            if let onRemove {
                Button { onRemove(entry.id) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary.opacity(0.5), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从清单去掉\(entry.name)")
            }
        }
        .padding(.leading, 14).padding(.trailing, onRemove == nil ? 14 : 4).padding(.vertical, 6)
    }

    private func subtitle(_ facts: LotFacts?) -> String {
        guard let facts else { return "物品已不存在" }
        if facts.state != .active { return "已处理 · 这张清单是之前列的" }
        var parts = ["\(facts.quantity) \(facts.unit)"]
        if let place = facts.storageLocation, !place.isEmpty { parts.append(place) }
        if let profile = facts.profile, profile.availability != "ready" { parts.append(profile.availabilityLabel) }
        else if !facts.quantityOnly, let days = facts.daysLeft, days <= 7 {
            parts.append(days < 0 ? facts.dateStatusLabel : days == 0 ? "今天到期" : "还有 \(facts.timeLeftLabel)")
        }
        return parts.joined(separator: " · ")
    }

    private func color(_ facts: LotFacts?) -> Color {
        guard let facts else { return .secondary }
        if facts.state != .active { return .orange }
        if let profile = facts.profile, profile.availability != "ready" { return .orange }
        guard !facts.quantityOnly, let days = facts.daysLeft else { return .secondary }
        return days < 0 ? .red : days <= 3 ? .orange : .secondary
    }
}
