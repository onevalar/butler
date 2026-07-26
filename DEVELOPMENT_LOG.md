# Butler Project Development Log & Handover Notes

## Butler 2.0 M2 source complete (debug-only)
**Date:** 2026-07-26

- Added the vendor-neutral planning boundary, deterministic bounded Chinese local planner, frozen-plan clarification revisions, exact catalog lookup, policy/review coordinator, and transactional V2 input flow.
- Debug builds can launch the isolated harness by adding `--m2-input-harness` to the scheme's launch arguments. The fixture “我今天买了一瓶牛奶、三包方便面和一个冰激凌。冰激凌先放冰箱了还没吃。” exercises conjunction splitting, later-clause detail association, and cold-storage clarification.
- The harness uses a temporary in-memory container and writes only `CatalogProduct` / `InventoryLot` through `InventoryRepository`; it cannot modify or leave invisible data in the normal app store. It does not write `Item`, merge products, or invoke legacy migration.
- The M2 coordinator, local planner, and V2 input UI are excluded from Release builds. M2 speech is on-device-only, while the unchanged legacy input retains its existing recognition fallback behavior.
- Production remains disabled: normal launches still show `ContentView` / the legacy Dashboard and input path. Enablement is blocked on M1 migration/build validation in macOS/Xcode and a Dashboard V2 read path.

## Butler 2.0 Foundation (M0 in progress)
**Date:** 2026-07-26

- The normative product/domain/AI contract is now [`docs/BUTLER_2_SPEC.md`](docs/BUTLER_2_SPEC.md).
- Added an additive V2 schema for products, inventory lots, field evidence, inventory events, recurring-product templates, and future legacy migration links.
- Added a versioned AI operation-plan contract and deterministic validation policy. It is intentionally not connected to persistence yet.
- Added an M1 transactional repository with exact replay conflict detection, revision checks, field evidence, trusted confirmations, and one event per operation.
- Added an explicit, idempotent legacy importer. It uses a fresh context, preserves the original Item snapshot, and conservatively treats all legacy dates as unverified estimates.
- Existing screens and `DataManager` still use the legacy `Item` model; there is no backfill or dual write.
- Before M0 can ship, compile and test old-store migration on macOS/Xcode. Do not delete or replace `Item` until V2 parity is proven.

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
