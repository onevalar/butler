//
//  ItemDetailSheet.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI

struct ItemDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataManager.self) private var dataManager
    
    @Bindable var item: Item
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(item.type.defaultColor.opacity(0.1))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: item.type.iconName)
                        .font(.system(size: 40))
                        .foregroundStyle(item.type.defaultColor)
                }
                
                VStack(spacing: 4) {
                    Text(item.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("\(item.quantity)\(item.unit ?? "个") • \(item.storageLocation ?? "未指定位置")")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 32)
            
            Divider()
            
            // Status Info
            VStack(spacing: 16) {
                DetailRow(
                    icon: "calendar",
                    iconColor: .blue,
                    title: "过期时间",
                    value: item.formattedExpiry,
                    subValue: item.daysRemaining.map { "\($0)天后" }
                )
                
                DetailRow(
                    icon: "circle.fill",
                    iconColor: item.statusColor,
                    title: "当前状态",
                    value: item.status.displayName
                )
                
                if let notes = item.notes {
                    DetailRow(
                        icon: "note.text",
                        iconColor: .gray,
                        title: "备注",
                        value: notes
                    )
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Actions
            VStack(spacing: 12) {
                Button {
                    dataManager.consumeItem(item)
                    dismiss()
                } label: {
                    Label("吃完了 / 用完了", systemImage: "fork.knife")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .foregroundStyle(.green)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                Button {
                    dataManager.discardItem(item)
                    dismiss()
                } label: {
                    Label("已丢弃", systemImage: "trash")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct DetailRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    var subValue: String? = nil
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            
            Text(title)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            HStack(spacing: 4) {
                Text(value)
                    .fontWeight(.medium)
                
                if let subValue {
                    Text("(\(subValue))")
                        .foregroundStyle(iconColor)
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ItemDetailSheet(
        item: .preview(name: "酸奶", type: .fresh, daysUntilExpiry: 3)
    )
    .environment(PreviewData.dataManager)
}
