import SwiftUI
import SwiftData

/// Stored recommendations reference real IDs; live facts replace stale quantities and availability.
struct InventoryResultView: View {
    let collection: ItemCollection
    let onOpen: (UUID) -> Void
    @Query private var lots: [InventoryLot]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(collection.title).font(.headline)
            ForEach(collection.items) { entry in
                let lot = lots.first { $0.id == entry.id }
                Button { onOpen(entry.id) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ItemPhoto(profile: lot?.itemProfile, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                            if let lot {
                                Text("\(lot.quantity) \(lot.unit) · \(lot.storageLocation ?? "位置未记录")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if lot.state != .active { Text("已处理 · 此建议来自之前的对话").font(.caption).foregroundStyle(.orange) }
                                else if let profile = lot.itemProfile, profile.availability != "ready" {
                                    Text(profile.availabilityLabel).font(.caption).foregroundStyle(.orange)
                                }
                                if let attributes = lot.itemProfile?.attributes, !attributes.isEmpty {
                                    Text(attributes.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value)" }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else { Text("物品已不存在").font(.caption).foregroundStyle(.secondary) }
                            Text(entry.reason).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(lot == nil)
                if entry.id != collection.items.last?.id { Divider() }
            }
        }.padding(16).glassCard(radius: 20)
    }
}
