//
//  CameraScanner.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI
import VisionKit

/// A wrapper around DataScannerViewController for SwiftUI
struct CameraScanner: UIViewControllerRepresentable {
    
    // Callback when a date is selected from the camera feed
    var onDateSelected: (Date) -> Void
    
    func makeUIViewController(context: Context) -> DataScannerViewController {
        // We look for text only
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            isHighlightingEnabled: true // Highlights text in yellow box
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // No updates needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: CameraScanner
        
        init(parent: CameraScanner) {
            self.parent = parent
        }
        
        // Handle user tap on highlighted item
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            switch item {
            case .text(let text):
                processText(text.transcript)
            default:
                break
            }
        }
        
        private func processText(_ text: String) {
            // Attempt to parse date
            if let date = DateParser.parse(text) {
                // Haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                
                // Return result
                parent.onDateSelected(date)
            } else {
                // Haptic feedback for failure
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
                print("Failed to parse date from: \(text)")
            }
        }
    }
}
