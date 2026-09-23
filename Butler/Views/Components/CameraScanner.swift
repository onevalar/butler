import SwiftUI
import VisionKit

/// Live text scanner. Tapping a highlighted date reports the parsed date and the raw text seen.
struct CameraScanner: UIViewControllerRepresentable {
    var onDateSelected: (Date, String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: CameraScanner

        init(parent: CameraScanner) { self.parent = parent }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case .text(let text) = item else { return }
            let feedback = UINotificationFeedbackGenerator()
            if let date = DateParser.parse(text.transcript) {
                feedback.notificationOccurred(.success)
                parent.onDateSelected(date, text.transcript)
            } else {
                feedback.notificationOccurred(.error)
            }
        }
    }
}
