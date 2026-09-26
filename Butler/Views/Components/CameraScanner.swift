import SwiftUI
import VisionKit

/// Live text scanner. Tapping a highlighted date reports the parsed date and the raw text seen.
struct CameraScanner: UIViewControllerRepresentable {
    var onDateSelected: (DateParser.Candidate, String) -> Void
    var onError: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch { DispatchQueue.main.async { onError("相机识别不可用，请手动选择日期。\(error.localizedDescription)") } }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: CameraScanner

        init(parent: CameraScanner) { self.parent = parent }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            parent.onError("相机识别已中断，请手动选择日期。")
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case .text(let text) = item else { return }
            let feedback = UINotificationFeedbackGenerator()
            let candidate = DateParser.candidate(in: text.transcript)
            feedback.notificationOccurred(candidate.date == nil ? .warning : .success)
            parent.onDateSelected(candidate, text.transcript)
        }
    }
}
