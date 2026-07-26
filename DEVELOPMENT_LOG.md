# Butler Project Development Log & Handover Notes

## 📌 Project Status: Phase 1 & 2 Complete (MVP Ready)
**Date:** 2026-01-06
**Current Version:** 0.1 (Internal Alpha)

---

## 🏗 System Architecture Summary

### 1. Data Layer (SwiftData)
- **Model**: `Item.swift`.
- **Logic Engine**: `DataManager.swift` (Singleton-like via Environment).
- **Butler Engine Rules**:
    - **R1**: Sensitive items (Fresh/Medicine) without dates -> `actionRequired`.
    - **R2**: General items without dates -> Auto-duration.
- **Undo System**: 5-second window for Consume/Discard/Decrement.

### 2. Voice Input (The "Brain")
- **Tech**: `SFSpeechRecognizer` (Forced On-Device) + `NLTagger` (Local NLP).
- **Location**: `Services/VoiceManager.swift` & `Services/NLPParser.swift`.
- **Parsing**: Handles `[Quantity] + [Item Name]` patterns.

### 3. Vision Correction (The "Eyes")
- **Tech**: `VisionKit` (`DataScannerViewController`).
- **Flow**: Highlighting dates on packaging -> Tap to populate -> Confirm.
- **Date Parsing**: `Services/DateParser.swift` handles multiple packaging date formats.

### 4. Search & Extension
- **In-App**: Semantic fuzzy search in `DashboardView` (e.g., searching "吃的").
- **Core Spotlight**: Full system search synchronization.
- **Widgets**: `ButlerWidget` with Small/Medium sizes.

---

## ⚠️ Known Issues & Technical Debts

### 1. Widget Data Sharing (App Group)
- **Problem**: Currently, the Widget uses `PreviewData` because real SwiftData sharing requires an **App Group Identifier**.
- **Fix Needed**: In a real provisioning environment, need to:
    1. Enable App Groups in "Signing & Capabilities".
    2. Update `ModelContainer` to use a shared App Group URL.
    3. Update `WidgetCenter` to fetch from that shared store.

### 2. On-Device Speech Recognition
- **Note**: `requiresOnDeviceRecognition = true` is set. It may fail on old devices or if the specific language pack (zh-CN) isn't downloaded. Fallback logic is in place but needs real-world testing.

### 3. OCR Performance
- **Note**: Packaging can be busy. The `DateParser` is currently rule-based. If parsing fails frequently, consider a more robust regex or a micro ML model for date detection.

---

## 🚀 Next Steps (Priority List)

1.  **UI Polish**:
    - Add transition animations when an item moves from "Inbox" to "Urgency Grid".
    - Enhance the `ItemCard` with item-specific icons based on name.
2.  **Product Refinement**:
    - Implementation of "Storage Locations" (e.g., Freezer vs Pantry) selection in `ItemDetailSheet`.
    - Notification system: Push notifications when items are about to expire.
3.  **App Clips / Shortcuts**:
    - Add Siri Shortcuts for "What's expiring today?".

---

## 🛠 Troubleshooting for "Future Me"
- **Build Errors?** Check `Info.plist`. It's managed via `PlistBuddy` and contains Camera/Speech/Microphone permissions.
- **Data Not Refreshing?** `DataManager.saveChanges()` is the central point for `WidgetCenter` reloads and Spotlight sync. Always use this instead of `modelContext.save()`.
- **Scanner Not Working?** Ensure you are testing on a **Real Device**. Simulators do not support `DataScannerViewController`.
