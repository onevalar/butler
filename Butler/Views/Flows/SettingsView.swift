//
//  SettingsView.swift
//  Butler
//
//  Created by 安宇佳 on 2026/2/7.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataManager.self) private var dataManager
    @Query private var allItems: [Item]
    
    @AppStorage("userName") private var userName: String = "用户"
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("expiryWarningDays") private var expiryWarningDays: Int = 3
    
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 个人信息
                Section("个人信息") {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("用户名", text: $userName)
                                .font(.title3)
                                .fontWeight(.semibold)
                            
                            Text("Butler 用户")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.vertical, 8)
                }
                
                // MARK: - 通知设置
                Section {
                    Toggle("启用过期提醒", isOn: $notificationsEnabled)
                    
                    if notificationsEnabled {
                        Stepper("提前 \(expiryWarningDays) 天提醒", value: $expiryWarningDays, in: 1...7)
                    }
                } header: {
                    Label("通知设置", systemImage: "bell.badge")
                } footer: {
                    if notificationsEnabled {
                        Text("Butler 会在物品过期前 \(expiryWarningDays) 天提醒你")
                    }
                }
                
                // MARK: - 数据统计
                Section {
                    HStack {
                        Label("总物品数", systemImage: "archivebox")
                        Spacer()
                        Text("\(allItems.count)")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Label("即将过期", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Text("\(criticalItemsCount)")
                            .foregroundStyle(.red)
                    }
                    
                    HStack {
                        Label("需要补全", systemImage: "doc.badge.ellipsis")
                        Spacer()
                        Text("\(actionRequiredCount)")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Label("数据统计", systemImage: "chart.bar")
                }
                
                // MARK: - 关于
                Section {
                    HStack {
                        Label("版本", systemImage: "info.circle")
                        Spacer()
                        Text("1.0.0 (Build 2026.02.07)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    
                    Link(destination: URL(string: "https://apple.com")!) {
                        Label("隐私政策", systemImage: "hand.raised")
                    }
                    
                    Link(destination: URL(string: "https://apple.com")!) {
                        Label("使用条款", systemImage: "doc.text")
                    }
                } header: {
                    Label("关于 Butler", systemImage: "app.badge")
                } footer: {
                    Text("Butler © 2026\n数据完全在本地处理，保护你的隐私")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                // MARK: - 危险操作
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("清除所有数据", systemImage: "trash")
                    }
                } header: {
                    Label("危险操作", systemImage: "exclamationmark.triangle.fill")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "确定要清除所有数据吗？",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("清除所有数据", role: .destructive) {
                    clearAllData()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作无法撤销，所有物品数据将被永久删除。")
            }
        }
    }
    
    // MARK: - Helper Properties
    
    private var criticalItemsCount: Int {
        allItems.filter { 
            $0.urgencyLevel == .critical || $0.urgencyLevel == .expired 
        }.count
    }
    
    private var actionRequiredCount: Int {
        allItems.filter { $0.status == .actionRequired }.count
    }
    
    // MARK: - Actions
    
    private func clearAllData() {
        for item in allItems {
            dataManager.deleteItem(item)
        }
        SpotlightManager.shared.clearAllIndexes()
        NotificationManager.shared.cancelAllNotifications()
        dismiss()
    }
}

#Preview {
    SettingsView()
        .environment(PreviewData.dataManager)
        .modelContainer(PreviewContainer.shared)
}
