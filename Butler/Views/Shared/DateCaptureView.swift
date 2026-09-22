import SwiftUI
import VisionKit
import SwiftData

/// Captures a real package expiry date: camera OCR when available, date wheel always.
/// Package dates are never estimated, so the user's final tap is the confirmation.
struct DateCaptureView: View {
    let lot: LotFacts

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var date = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var scannedDate: Date?
    @State private var scannedText: String?
    @State private var errorMessage: String?

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if scannerAvailable {
                    CameraScanner { found, text in
                        withAnimation(.snappy) {
                            date = found
                            scannedDate = found
                            scannedText = text
                        }
                    }
                } else {
                    Theme.capsule
                    VStack(spacing: 10) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 44, weight: .thin))
                        Text("这台设备不能用相机识别，直接选日期就好")
                            .font(Theme.body(13))
                    }
                    .foregroundStyle(Theme.capsuleText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .padding(.leading, 20)
                .padding(.top, 12)
                .accessibilityLabel("关闭")
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    SealView(glyph: lot.glyph, style: .solid, size: 48, tilt: -5)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(scannedDate == nil ? "对准包装上的日期，轻点它" : "识别到了，确认一下", color: Theme.muted)
                        Text("\(lot.name)哪天过期？")
                            .font(Theme.display(22))
                            .foregroundStyle(Theme.ink)
                    }
                }
                DatePicker("包装有效期", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()
                Button("就是这天", action: save)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Text("这是包装上印的日期，我会按它提醒你")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                    .fill(Theme.ground)
                    .ignoresSafeArea(edges: .bottom)
            )
            .offset(y: -24)
            .padding(.bottom, -24)
        }
        .background(Theme.ground.ignoresSafeArea())
        .alert("没能保存", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let fromScan = scannedDate.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
        do {
            try InventoryActions(modelContainer: modelContext.container).setPackageExpiry(
                date, for: lot,
                source: fromScan ? .ocr : .userEdited,
                rawText: fromScan ? scannedText : nil
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
