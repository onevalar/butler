import SwiftUI
import VisionKit
import SwiftData

/// Captures a real package expiry date: camera OCR when available, date wheel always.
/// Package dates are never estimated, so the user's final tap is the confirmation.
struct DateCaptureView: View {
    let lot: LotFacts

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var date = Date.now
    @State private var hasSelectedDate = false
    @State private var confirmedExpiry = false
    @State private var scanGuidance: String?
    @State private var scannerError: String?
    @State private var scannedDate: Date?
    @State private var scannedText: String?
    @State private var errorMessage: String?

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if scannerAvailable && scannerError == nil {
                    CameraScanner { candidate, text in
                        withAnimation(.snappy) {
                            if let found = candidate.date { date = found }
                            hasSelectedDate = candidate.date != nil
                            confirmedExpiry = false
                            scannedDate = candidate.date
                            scannedText = text
                            scanGuidance = candidate.guidance
                        }
                    } onError: { scannerError = $0 }
                } else {
                    Theme.capsule
                    VStack(spacing: 10) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 44, weight: .thin))
                        Text(scannerError ?? "这台设备不能用相机识别，直接选日期就好")
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
                if let scanGuidance {
                    Text(scanGuidance).font(Theme.body(12)).foregroundStyle(Theme.ink)
                }
                DatePicker("包装有效期", selection: Binding(get: { date }, set: {
                    date = $0
                    hasSelectedDate = true
                    confirmedExpiry = false
                    scannedDate = nil
                }), displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 216)
                    .clipped()
                    .contentShape(Rectangle())
                if !hasSelectedDate {
                    Button("选择显示的日期（\(date.formatted(date: .numeric, time: .omitted))）") {
                        hasSelectedDate = true
                    }
                }
                Toggle("我已核对：这是包装有效期，不是生产日期", isOn: $confirmedExpiry)
                    .font(Theme.body(12))
                    .disabled(!hasSelectedDate)
                Button("确认包装有效期", action: save)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!hasSelectedDate || !confirmedExpiry)
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
        guard hasSelectedDate && confirmedExpiry else { return }
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
