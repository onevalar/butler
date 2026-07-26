//
//  VisionCorrectionView.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI
import VisionKit

struct VisionCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataManager.self) private var dataManager
    
    @Bindable var item: Item
    
    @State private var selectedDate: Date = Date()
    @State private var isAnimating: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
            // MARK: - Top Half: Visual Evidence
            ZStack {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    CameraScanner { date in
                        // Auto-fill the picker
                        withAnimation {
                            selectedDate = date
                        }
                    }
                } else {
                    // Fallback for Simulator or unauthorized
                    ZStack {
                        Color.black
                        VStack(spacing: 16) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 60, weight: .thin))
                                .foregroundStyle(.white.opacity(0.8))
                            Text("相机不可用")
                                .foregroundStyle(.white.opacity(0.8))
                            Text("请在真机运行以体验 OCR")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                    }
                }

                // Overlay Gradient
                LinearGradient(
                    colors: [.black.opacity(0.6), .clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false) // Allow tapping through to scanner

                // Item Name Overlay
                VStack {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("补全信息")
                                .font(.caption)
                                .textCase(.uppercase)
                                .foregroundStyle(.white.opacity(0.6))
                            Text(item.name)
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        }
                        Spacer()

                        // Close Button
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding()
                    .padding(.top, 20)

                    Spacer()
                }
            }
            .frame(height: geometry.size.height * 0.45)
            
            // MARK: - Bottom Half: Controls
            VStack(spacing: 24) {
                // Instruction
                HStack {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.blue)
                    Text("请确认过期时间")
                        .font(.headline)
                    Spacer()
                }
                .padding(.top, 24)
                .padding(.horizontal)
                
                // Date Picker (Wheel Style)
                DatePicker(
                    "Expiry Date",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxHeight: .infinity)
                
                // Confirm Button
                Button {
                    // Logic: Verify and Save
                    withAnimation {
                        dataManager.verifyExpiryDate(item, date: selectedDate)
                        dismiss()
                    }
                } label: {
                    Text("确认归档")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedCorner(radius: 24, corners: [.topLeft, .topRight]))
            .offset(y: -24) // Overlap effect
        }
        .ignoresSafeArea()
        } // GeometryReader
    }
}

// MARK: - Helper Shape

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Preview

#Preview {
    VisionCorrectionView(
        item: .preview(name: "牛奶", type: .fresh, status: .actionRequired)
    )
    .environment(PreviewData.dataManager)
}
