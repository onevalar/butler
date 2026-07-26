//
//  DashboardView.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI
import SwiftData
import CoreSpotlight

struct DashboardView: View {
    @Environment(DataManager.self) private var dataManager
    @Query private var items: [Item]
    
    @State private var searchText: String = ""
    
    // MARK: - Computed Properties for Sections
    
    private var filteredItems: [Item] {
        if searchText.isEmpty {
            return items
        } else {
            return items.filter { item in
                let lowercasedSearch = searchText.lowercased()
                
                // 1. Exact match on name
                if item.name.lowercased().contains(lowercasedSearch) { return true }
                
                // 2. Exact match on type
                if item.type.displayName.lowercased().contains(lowercasedSearch) { return true }
                
                // 3. Simple Semantic/Fuzzy Search
                // "吃的" (food)
                if lowercasedSearch.contains("吃的") || lowercasedSearch.contains("食品") {
                    return item.type == .fresh || item.type == .pantry
                }
                
                // "药" (medicine)
                if lowercasedSearch.contains("药") {
                    return item.type == .medicine
                }
                
                // "快过期" (expiring soon)
                if lowercasedSearch.contains("快过期") || lowercasedSearch.contains("赶紧吃") {
                    return item.urgencyLevel == .critical || item.urgencyLevel == .expired
                }
                
                // "待办" / "补全" (action required)
                if lowercasedSearch.contains("待办") || lowercasedSearch.contains("补全") || lowercasedSearch.contains("作业") {
                    return item.status == .actionRequired
                }
                
                return false
            }
        }
    }
    
    private var actionRequiredItems: [Item] {
        filteredItems.filter { $0.status == .actionRequired }
    }
    
    private var criticalItems: [Item] {
        filteredItems.filter { $0.status == .active && ($0.urgencyLevel == .expired || $0.urgencyLevel == .critical) }
            .sorted { ($0.daysRemaining ?? Int.max) < ($1.daysRemaining ?? Int.max) }
    }
    
    private var warningItems: [Item] {
        filteredItems.filter { $0.status == .active && $0.urgencyLevel == .warning }
            .sorted { ($0.daysRemaining ?? Int.max) < ($1.daysRemaining ?? Int.max) }
    }
    
    private var safeItems: [Item] {
        filteredItems.filter { $0.status == .active && ($0.urgencyLevel == .safe || $0.urgencyLevel == .unknown) }
            .sorted { ($0.daysRemaining ?? Int.max) < ($1.daysRemaining ?? Int.max) }
    }
    
    // MARK: - Greeting Logic
    
    private var greetingText: String {
        if !actionRequiredItems.isEmpty {
            return "有 \(actionRequiredItems.count) 件物品需补全信息"
        } else if !criticalItems.isEmpty {
            return "注意：\(criticalItems.count) 件物品即将过期"
        } else if !warningItems.isEmpty {
            return "提醒：\(warningItems.count) 件物品本周过期"
        } else {
            return "一切安好，库存充足 ✨"
        }
    }
    
    private var greetingColor: Color {
        if !actionRequiredItems.isEmpty { return .orange }
        if !criticalItems.isEmpty { return .red }
        if !warningItems.isEmpty { return .yellow }
        return .green
    }
    
    @State private var selectedItem: Item?
    @State private var showVoiceInput: Bool = false
    @State private var showSettings: Bool = false
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    
                    // Greeting Header
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Good Day,")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(greetingText)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(greetingColor)
                        }
                        Spacer()
                        
                        // Profile/Settings Button
                        Button {
                            showSettings = true
                        } label: {
                            Circle()
                                .fill(Color.secondary.opacity(0.1))
                                .frame(width: 40, height: 40)
                                .overlay {
                                    Image(systemName: "person.crop.circle")
                                        .font(.title2)
                                        .foregroundStyle(.primary)
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    
                    // Inbox Section (Only show if needed)
                    if !actionRequiredItems.isEmpty {
                        InboxSection(items: actionRequiredItems) { item in
                            selectedItem = item
                        }
                    }
                    
                    // Grid Section
                    UrgencyGridSection(
                        criticalItems: criticalItems,
                        warningItems: warningItems,
                        safeItems: safeItems,
                        onItemTap: { item in
                            selectedItem = item
                        }
                    )
                    
                    // Bottom Spacer for FAB
                    Color.clear.frame(height: 80)
                }
            }
            .searchable(text: $searchText, prompt: "查找‘吃的’或‘快过期的’...")
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbarVisibility(.hidden, for: .navigationBar)
            .toolbar {
                // Undo Button (Top-level toolbar doesn't work well with hidden navbar,
                // but we might want global undo later. For now relying on toast or similar)
            }
            .overlay(alignment: .bottom) {
                // Main Action Button (Text Input)
                Button {
                    showVoiceInput = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "text.bubble.fill")
                            .font(.title2)
                        Text("添加物品")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 32)
                    .background {
                        Capsule()
                            .fill(Color.accentColor)
                            .shadow(color: Color.accentColor.opacity(0.4), radius: 10, x: 0, y: 6)
                    }
                }
                .padding(.bottom, 20)
            }
            // Undo Toast Overlay
            .overlay(alignment: .bottom) {
                if dataManager.canUndo {
                    Button {
                        withAnimation {
                            _ = dataManager.undoLastAction()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.uturn.backward")
                            Text("撤销操作")
                        }
                        .padding()
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                        .shadow(radius: 4)
                    }
                    .padding(.bottom, 100) // Above FAB
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $showVoiceInput) {
                VoiceInputView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedItem) { item in
                if item.status == .actionRequired {
                    VisionCorrectionView(item: item)
                } else {
                    ItemDetailSheet(item: item)
                }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
                guard let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                      let uuid = UUID(uuidString: identifier) else { return }
                
                // Find the item in our data
                if let item = items.first(where: { $0.id == uuid }) {
                    selectedItem = item
                }
            }
        }
    }
}

#Preview {
    DashboardView()
        .environment(PreviewData.dataManager)
        .modelContainer(PreviewContainer.shared)
}
