//
//  ItemCard.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI

struct ItemCard: View {
    let item: Item
    var showQuickActions: Bool = false
    
    // Aesthetic constants
    private let cardCornerRadius: CGFloat = 16
    private let iconSize: CGFloat = 32
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Icon and Days Remaining
            HStack(alignment: .top) {
                // Item Icon Container
                ZStack {
                    Circle()
                        .fill(item.type.defaultColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: item.type.iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(item.type.defaultColor)
                }
                
                Spacer()
                
                // Urgency/Status Badge
                if item.status == .actionRequired {
                    StatusBadge(text: "待补全", color: .orange, icon: "exclamationmark.triangle.fill")
                } else {
                    StatusBadge(
                        text: item.expiryDescription,
                        color: item.statusColor,
                        icon: item.status == .active ? nil : "clock.fill" // Simplified logic
                    )
                }
            }
            
            Spacer(minLength: 0)
            
            // Content: Name and Details
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                
                HStack(spacing: 6) {
                    Text("\(item.quantity)\(item.unit ?? "个")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if let location = item.storageLocation {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(location)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        }
        .overlay {
            // Optional border for high urgency items
            if item.urgencyLevel == .expired || item.urgencyLevel == .critical {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(item.statusColor.opacity(0.3), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Helper Views

struct StatusBadge: View {
    let text: String
    let color: Color
    var icon: String? = nil
    
    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

// MARK: - Previews

#Preview("Standard Card") {
    ZStack {
        Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        ItemCard(item: .preview(name: "牛奶", type: .fresh, daysUntilExpiry: 5))
            .frame(width: 180, height: 160)
            .padding()
    }
}

#Preview("Action Required") {
    ZStack {
        Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        ItemCard(item: .preview(name: "未知肉类", type: .fresh, status: .actionRequired, daysUntilExpiry: nil))
            .frame(width: 180, height: 160)
            .padding()
    }
}

#Preview("Critical") {
    ZStack {
        Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        ItemCard(item: .preview(name: "过期面包", type: .pantry, daysUntilExpiry: -1))
            .frame(width: 180, height: 160)
            .padding()
    }
}
