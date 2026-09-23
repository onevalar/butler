# Butler Project Development Log & Handover Notes

## 听懂日常说法：本地中文解析器重写
**Date:** 2026-09-23 · Xcode 26.3 · iOS 26.2 Simulator (iPhone 17)

- Owner's phone has no Apple Intelligence, so the on-device Foundation Models route was dropped for now. `LocalInventoryPlanProvider` now uses `ChineseInventoryParser` + `ProductLexicon` (still fully on-device, no upload).
- Understands: missing amounts (defaults to 1, marked as estimate), vague amounts (点/些/几), 一打/半打, name-first amounts (牛奶两瓶), run-together lists without punctuation, 喝完了又买了两瓶, filler/hesitation words, 给宝宝…, weights (recorded as 1 份 with a note), storage before or after the item, 都放…, spoken package dates (明天过期 / 还有三天过期 / 10月5号过期), shelf life (保质期七天 → estimated), spoken plans (三天内喝掉 / 这周吃掉 / 尽快).
- Question policy: 冰箱 → 冷藏 inferred for fresh/produce; asked only for freezables (ice cream, meat, dumplings). Loose produce gets a typical-life plan suggestion instead of a photo request; packaged fresh food and medicine never get guessed dates.
- Re-purchases link to the single same-name product without asking; the review shows "家里已有同款 · 改" to undo. Multiple same-name products still ask. (Adjusts spec §8.5's "explicit choice" rule: the review screen is the confirmation.)
- Talking about finishing something ("牛奶喝完了") explains that this is done on the item page instead of misrecording.
- Speech recognition now requests punctuation. Review shows defaulted quantities with the dashed "我推断的" underline.
- Tests: 42 passed (sentence-level parser suite added). Extend `ProductLexicon` to teach new products.

## V2 直接接入与“青花”界面
**Date:** 2026-09-22 · Xcode 26.3 · iOS 26.2 Simulator (iPhone 17)

- Owner decision: legacy `Item` UI/`DataManager` removed; the app reads and writes V2 only (see spec §7 items 7–8). `Item` stays in the schema so existing stores open.
- New UI (Home / Capture / Clarify / Review / Detail / Inventory / Date capture) built from the Paper "butler" designs, light + dark. Design tokens live in `Butler/Design/Theme.swift`.
- Input pipeline (`InventoryInputCoordinator`, `LocalInventoryPlanProvider`) is now production code. Added "先跳过" (keeps the literal 冰箱, Home asks later) and a compartment answer that records a `systemEstimate` plan date, never a package date.
- Button commands go through `InventoryActions` (single-op plans, policy-issued receipts on explicit tap). Reminders and Spotlight are rebuilt from active lots on every change.
- Fixed: app target never used `Butler/Info.plist`, so mic/camera/speech usage strings were missing (crash on first mic use). Fixed a Swift 6.2 runtime crash when `@MainActor` classes deinit on the main thread (`nonisolated deinit`).
- Tests: 13 passed, 1 pre-existing skip. Simulator walkthrough of the spec §8.5 sentence verified end to end.
- Debug aids: `--seed-sample-inventory` launch argument; `BUTLER_CAPTURE_TEXT` env var opens Capture pre-filled.
- Fonts: Noto Serif SC Regular/SemiBold/Bold bundled (OFL, subset to GB2312 + app strings, ~8.5 MB total; rarer characters fall back to the system font). Re-run the subset if new UI copy uses characters outside GB2312. License notices in `Butler/Resources/Fonts`.
- Open: real-device voice not yet tested.

## Butler 2.0 M0–M2 source handoff
**Date:** 2026-07-26

- Repository state at handoff: M0 domain/schema and policy source is complete; M1 repository and explicit migrator source is complete; M2 input loop source is complete as a debug-only harness. None of these milestones is release-validated until the macOS/Xcode checklist below passes.
- Added the vendor-neutral planning boundary, deterministic bounded Chinese local planner, frozen-plan clarification revisions, exact catalog lookup, policy/review coordinator, and transactional V2 input flow.
- Debug builds can launch the isolated harness by adding `--m2-input-harness` to the scheme's launch arguments. The fixture “我今天买了一瓶牛奶、三包方便面和一个冰激凌。冰激凌先放冰箱了还没吃。” exercises conjunction splitting, later-clause detail association, and cold-storage clarification.
- The harness uses a temporary in-memory container and writes only `CatalogProduct` / `InventoryLot` through `InventoryRepository`; it cannot modify or leave invisible data in the normal app store. It does not write `Item`, merge products, or invoke legacy migration.
- The M2 coordinator, local planner, and V2 input UI are excluded from Release builds. M2 speech is on-device-only, while the unchanged legacy input retains its existing recognition fallback behavior.
- Production remains disabled: normal launches still show `ContentView` / the legacy Dashboard and input path. Enablement is blocked on M1 migration/build validation in macOS/Xcode and a Dashboard V2 read path.

- The normative product/domain/AI contract is now [`docs/BUTLER_2_SPEC.md`](docs/BUTLER_2_SPEC.md).
- Added an additive V2 schema for products, inventory lots, field evidence, inventory events, recurring-product templates, and future legacy migration links.
- Added a versioned AI operation-plan contract and deterministic validation policy. Only the debug M2 coordinator connects validated plans to persistence; the Release app does not.
- Added an M1 transactional repository with exact replay conflict detection, revision checks, field evidence, trusted confirmations, and one event per operation.
- Added an explicit, idempotent legacy importer. It uses a fresh context, preserves the original Item snapshot, and conservatively treats all legacy dates as unverified estimates.
- Existing screens and `DataManager` still use the legacy `Item` model; there is no backfill or dual write.
- Before M0 can ship, compile and test old-store migration on macOS/Xcode. Do not delete or replace `Item` until V2 parity is proven.

### Mandatory macOS/Xcode handoff checklist

The current project has an application target only; it does not yet have a test target. Perform these tasks on macOS with Xcode 26.2 and the iOS 26.2 SDK, and record results here before enabling any V2 production path:

- [ ] Create a `ButlerTests` target and make M0–M2 domain/persistence code testable without changing Release behavior.
- [ ] Build the Butler scheme in both Debug and Release. Treat SwiftData macro, predicate, uniqueness, Observation, actor-isolation, and warning failures as blockers.
- [ ] Verify a clean installation can create and reopen the complete `ButlerStore.schema`.
- [ ] Generate a temporary database with the legacy `Item`-only schema, populate every compatibility fixture listed in `docs/BUTLER_2_SPEC.md`, then open that same file with the complete schema. Compare every legacy row and field before and after.
- [ ] Force a store-opening/migration failure and verify Butler neither deletes nor silently recreates the user's database.
- [ ] Test `InventoryRepository`: atomic rollback, exact idempotent replay, conflicting operation-ID rejection, stale revision rejection, missing entity handling, confirmation binding, evidence values, event creation, and integer overflow boundaries.
- [ ] Test `LegacyItemMigrator`: explicit invocation only, second-run idempotency, one link per old Item, conservative one-Product/one-Lot mapping, original snapshot preservation, and all legacy dates remaining unverified estimates.
- [ ] Launch Debug with `--m2-input-harness`. Confirm the default sentence creates exactly three review rows; only ice-cream storage is clarified; noodles receive a three-calendar-month `plannedUseByDate` and no `packageExpiryDate`; clarification preserves IDs; and no write occurs before final review confirmation.
- [ ] Verify exact-name product candidates never merge automatically, arbitrary candidate IDs are rejected, and confirmed existing-product selection rewires only the intended lot.
- [ ] Relaunch normally after using the harness and confirm the production store is unchanged. Confirm Release contains no M2 harness entry path.
- [ ] On simulator and a physical device, verify microphone/speech permissions, M2 on-device-only failure messaging, and the legacy local-first/server-fallback behavior. Do not approve cloud model upload as part of this test.
- [ ] Run legacy regression coverage for Dashboard, details, consume, discard, date completion, notifications, Spotlight, cold launch, and background/foreground transitions.
- [ ] Before production enablement, implement and verify a V2 Dashboard/read path. Only afterward may an explicit migration entry point or production M2 writer be considered; do not introduce dual-write.

Detailed fixtures, expected outcomes, and release gates are normative in [`docs/BUTLER_2_SPEC.md`](docs/BUTLER_2_SPEC.md#8-macosxcode-验证与发布门禁).

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
