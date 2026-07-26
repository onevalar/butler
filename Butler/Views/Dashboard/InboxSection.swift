//
//  InboxSection.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI

struct InboxSection: View {
    let items: [Item]
    var onItemTap: (Item) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("待处理", systemImage: "tray.full.fill")
                .font(.headline) // Matching section header style
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(items) { item in
                        ItemCard(item: item)
                            .frame(width: 160, height: 160) // Fixed size for horizontal scroll
                            .onTapGesture {
                                onItemTap(item)
                            }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20) // Specs for shadow and spacing
            }
        }
    }
}

#Preview {
    ZStack {
        Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        InboxSection(items: [
            .preview(name: "牛奶", type: .fresh, status: .actionRequired),
            .preview(name: "牛肉", type: .fresh, status: .actionRequired)
        ], onItemTap: { item in
            print("Tapped: \(item.name)")
        })
    }
}
