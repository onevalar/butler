//
//  VoiceInputView_Preview.swift
//  Butler
//
//  Created for testing UI in Xcode Preview
//

import SwiftUI
import SwiftData

// 这个文件专门用于在 Xcode Preview 中测试 VoiceInputView 的界面效果

#Preview("空状态") {
    VoiceInputView()
        .environment(PreviewData.dataManager)
}

#Preview("已填充文本") {
    struct PreviewWrapper: View {
        @State private var showSheet = true
        
        var body: some View {
            Color.clear
                .sheet(isPresented: $showSheet) {
                    VoiceInputView()
                        .environment(PreviewData.dataManager)
                }
        }
    }
    
    return PreviewWrapper()
}

#Preview("在 DashboardView 中") {
    DashboardView()
        .environment(PreviewData.dataManager)
        .modelContainer(PreviewContainer.shared)
}

// 测试不同设备尺寸
#Preview("iPhone SE") {
    VoiceInputView()
        .environment(PreviewData.dataManager)
        .previewDevice("iPhone SE (3rd generation)")
}

#Preview("iPhone 15 Pro") {
    VoiceInputView()
        .environment(PreviewData.dataManager)
        .previewDevice("iPhone 15 Pro")
}

#Preview("iPhone 15 Pro Max") {
    VoiceInputView()
        .environment(PreviewData.dataManager)
        .previewDevice("iPhone 15 Pro Max")
}

#Preview("iPad") {
    VoiceInputView()
        .environment(PreviewData.dataManager)
        .previewDevice("iPad Pro (12.9-inch) (6th generation)")
}

// 测试深色模式
#Preview("深色模式") {
    VoiceInputView()
        .environment(PreviewData.dataManager)
        .preferredColorScheme(.dark)
}

// 测试浅色模式
#Preview("浅色模式") {
    VoiceInputView()
        .environment(PreviewData.dataManager)
        .preferredColorScheme(.light)
}
