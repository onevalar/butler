//
//  UrgencyGridSection.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI

struct UrgencyGridSection: View {
    let criticalItems: [Item]
    let warningItems: [Item]
    let safeItems: [Item]
    var onItemTap: (Item) -> Void
    
    @State private var isSafeZoneExpanded: Bool = false
    
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    var body: some View {
        VStack(spacing: 24) {
            
            // MARK: - Red Zone (Critical)
            if !criticalItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "即将过期", icon: "exclamationmark.circle.fill", color: .red)
                    
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(criticalItems) { item in
                            ItemCard(item: item)
                                .frame(height: 160)
                                .onTapGesture { onItemTap(item) }
                        }
                    }
                }
            }
            
            // MARK: - Yellow Zone (Warning)
            if !warningItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "建议尽快使用", icon: "clock.badge.exclamationmark.fill", color: .orange)
                    
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(warningItems) { item in
                            ItemCard(item: item)
                                .frame(height: 160)
                                .onTapGesture { onItemTap(item) }
                        }
                    }
                }
            }
            
            // MARK: - Green Zone (Safe)
            if !safeItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        withAnimation {
                            isSafeZoneExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            SectionHeader(title: "库存充足", icon: "checkmark.circle.fill", color: .green)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(isSafeZoneExpanded ? 90 : 0))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if isSafeZoneExpanded {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(safeItems) { item in
                                ItemCard(item: item)
                                    .frame(height: 160)
                                    .onTapGesture { onItemTap(item) }
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        // Teaser row (first 2 items) — match LazyVGrid's two-column layout
                        HStack(spacing: 16) {
                            ForEach(safeItems.prefix(2)) { item in
                                ItemCard(item: item)
                                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160)
                                    .scaleEffect(0.95)
                                    .opacity(0.8)
                                    .onTapGesture { onItemTap(item) }
                            }
                            // Placeholder column when only 1 item exists
                            if safeItems.count == 1 {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Helper Components

struct SectionHeader: View {
    let title: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.primary)
        }
    }
}

// MARK: - Previews

#Preview {
    ScrollView {
        UrgencyGridSection(
            criticalItems: [
                .preview(name: "过期牛奶", type: .fresh, daysUntilExpiry: -1),
                .preview(name: "快过期面包", type: .pantry, daysUntilExpiry: 1)
            ],
            warningItems: [
                .preview(name: "苹果", type: .fresh, daysUntilExpiry: 5)
            ],
            safeItems: [
                .preview(name: "大米", type: .pantry, daysUntilExpiry: 100),
                .preview(name: "罐头", type: .pantry, daysUntilExpiry: 300),
                .preview(name: "水", type: .pantry, daysUntilExpiry: 365)
            ],
            onItemTap: { item in
                print("Tapped: \(item.name)")
            }
        )
    }
    .background(Color(uiColor: .systemGroupedBackground))
}
