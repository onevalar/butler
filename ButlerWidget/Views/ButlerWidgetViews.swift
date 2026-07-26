//
//  ButlerWidgetViews.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI
import WidgetKit

// MARK: - Small Widget

struct ButlerSmallWidget: View {
    let items: [Item]
    
    var criticalCount: Int {
        items.filter { $0.urgencyLevel == .critical || $0.urgencyLevel == .expired }.count
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shield.fill")
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(items.count)")
                    .font(.system(.title3, design: .rounded))
                    .bold()
            }
            
            Spacer()
            
            Text("预警状态")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if criticalCount > 0 {
                Text("\(criticalCount) 件紧急")
                    .font(.headline)
                    .foregroundStyle(.red)
            } else {
                Text("暂无过期")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
        }
        .padding()
    }
}

// MARK: - Medium Widget

struct ButlerMediumWidget: View {
    let items: [Item]
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Side: Summary
            VStack(alignment: .leading) {
                Text("Butler")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.blue)
                
                Spacer()
                
                Text("\(items.count)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("总库存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            
            Divider()
                .padding(.vertical)
            
            // Right Side: List
            VStack(alignment: .leading, spacing: 10) {
                if items.isEmpty {
                    Text("所有物品都很安全 ✨")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items.prefix(3), id: \.id) { item in
                        HStack {
                            Circle()
                                .fill(item.statusColor)
                                .frame(width: 8, height: 8)
                            
                            Text(item.name)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                            
                            Spacer()
                            
                            Text(item.expiryDescription)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
