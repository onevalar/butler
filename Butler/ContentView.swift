//
//  ContentView.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var dataManager: DataManager?

    var body: some View {
        Group {
            if let dataManager {
                DashboardView()
                    .environment(dataManager)
            } else {
                ProgressView()
                    .onAppear {
                        dataManager = DataManager(modelContext: modelContext)
                    }
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(PreviewContainer.shared)
}
