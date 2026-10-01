#!/usr/bin/env bash
set -euo pipefail
# Runs Foundation-only system journals; does not test AlarmKit or EventKit.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/Butler" "$scratch/Tests/ButlerTests"
ln -s "$root/Butler/Domain/ButlerAlarm.swift" "$scratch/Sources/Butler/ButlerAlarm.swift"
ln -s "$root/Butler/Services/AlarmStore.swift" "$scratch/Sources/Butler/AlarmStore.swift"
ln -s "$root/ButlerTests/AlarmStoreTests.swift" "$scratch/Tests/ButlerTests/AlarmStoreTests.swift"
ln -s "$root/Butler/Domain/AppleReminder.swift" "$scratch/Sources/Butler/AppleReminder.swift"
ln -s "$root/Butler/Services/AppleReminderStore.swift" "$scratch/Sources/Butler/AppleReminderStore.swift"
ln -s "$root/ButlerTests/AppleReminderStoreTests.swift" "$scratch/Tests/ButlerTests/AppleReminderStoreTests.swift"
ln -s "$root/Butler/Domain/SystemCalendar.swift" "$scratch/Sources/Butler/SystemCalendar.swift"
ln -s "$root/Butler/Services/SystemCalendarStore.swift" "$scratch/Sources/Butler/SystemCalendarStore.swift"
ln -s "$root/ButlerTests/SystemCalendarStoreTests.swift" "$scratch/Tests/ButlerTests/SystemCalendarStoreTests.swift"
ln -s "$root/Butler/Services/ShortcutNavigation.swift" "$scratch/Sources/Butler/ShortcutNavigation.swift"
ln -s "$root/ButlerTests/ShortcutNavigationTests.swift" "$scratch/Tests/ButlerTests/ShortcutNavigationTests.swift"
ln -s "$root/ButlerShareShared/ShareInbox.swift" "$scratch/Sources/Butler/ShareInbox.swift"
ln -s "$root/ButlerTests/ShareInboxTests.swift" "$scratch/Tests/ButlerTests/ShareInboxTests.swift"
ln -s "$root/ButlerWidgetShared/WidgetSnapshot.swift" "$scratch/Sources/Butler/WidgetSnapshot.swift"
ln -s "$root/ButlerTests/WidgetSnapshotTests.swift" "$scratch/Tests/ButlerTests/WidgetSnapshotTests.swift"
ln -s "$root/Butler/Services/TaskDisplayStore.swift" "$scratch/Sources/Butler/TaskDisplayStore.swift"
ln -s "$root/ButlerTests/TaskDisplayStoreTests.swift" "$scratch/Tests/ButlerTests/TaskDisplayStoreTests.swift"
ln -s "$root/Butler/Domain/HealthData.swift" "$scratch/Sources/Butler/HealthData.swift"
ln -s "$root/Butler/Services/HealthStore.swift" "$scratch/Sources/Butler/HealthStore.swift"
ln -s "$root/ButlerTests/HealthStoreTests.swift" "$scratch/Tests/ButlerTests/HealthStoreTests.swift"
ln -s "$root/Butler/Domain/HomeControl.swift" "$scratch/Sources/Butler/HomeControl.swift"
ln -s "$root/Butler/Services/HomeStore.swift" "$scratch/Sources/Butler/HomeStore.swift"
ln -s "$root/ButlerTests/HomeStoreTests.swift" "$scratch/Tests/ButlerTests/HomeStoreTests.swift"
ln -s "$root/Butler/Domain/ContactData.swift" "$scratch/Sources/Butler/ContactData.swift"
ln -s "$root/Butler/Services/ContactsStore.swift" "$scratch/Sources/Butler/ContactsStore.swift"
ln -s "$root/ButlerTests/ContactsStoreTests.swift" "$scratch/Tests/ButlerTests/ContactsStoreTests.swift"
ln -s "$root/Butler/Domain/TravelData.swift" "$scratch/Sources/Butler/TravelData.swift"
ln -s "$root/Butler/Services/TravelStore.swift" "$scratch/Sources/Butler/TravelStore.swift"
ln -s "$root/ButlerTests/TravelStoreTests.swift" "$scratch/Tests/ButlerTests/TravelStoreTests.swift"
ln -s "$root/Butler/Domain/SyncRecord.swift" "$scratch/Sources/Butler/SyncRecord.swift"
ln -s "$root/Butler/Services/SyncStore.swift" "$scratch/Sources/Butler/SyncStore.swift"
ln -s "$root/ButlerTests/SyncStoreTests.swift" "$scratch/Tests/ButlerTests/SyncStoreTests.swift"
ln -s "$root/Butler/Services/PhotoSyncData.swift" "$scratch/Sources/Butler/PhotoSyncData.swift"
ln -s "$root/ButlerTests/PhotoSyncDataTests.swift" "$scratch/Tests/ButlerTests/PhotoSyncDataTests.swift"
ln -s "$root/Butler/Services/LocalAgent.swift" "$scratch/Sources/Butler/LocalAgent.swift"
ln -s "$root/ButlerTests/LocalAgentTests.swift" "$scratch/Tests/ButlerTests/LocalAgentTests.swift"
ln -s "$root/Butler/Services/PublicWebPage.swift" "$scratch/Sources/Butler/PublicWebPage.swift"
ln -s "$root/ButlerTests/PublicWebPageTests.swift" "$scratch/Tests/ButlerTests/PublicWebPageTests.swift"
ln -s "$root/Butler/Services/AuthorizedFolderStore.swift" "$scratch/Sources/Butler/AuthorizedFolderStore.swift"
ln -s "$root/Butler/Services/FolderFileIO.swift" "$scratch/Sources/Butler/FolderFileIO.swift"
ln -s "$root/Butler/Services/ConfirmationJournal.swift" "$scratch/Sources/Butler/ConfirmationJournal.swift"
ln -s "$root/ButlerTests/FolderAndRecoveryTests.swift" "$scratch/Tests/ButlerTests/FolderAndRecoveryTests.swift"
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ButlerAlarmCore", targets: [
    .target(name: "Butler", swiftSettings: [.defaultIsolation(MainActor.self)]),
    .testTarget(name: "ButlerTests", dependencies: ["Butler"])
], swiftLanguageModes: [.v5])
SWIFT
swift test --package-path "$scratch"
