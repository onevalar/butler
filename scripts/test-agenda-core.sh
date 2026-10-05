#!/usr/bin/env bash
set -euo pipefail
# Executes the actual agenda construction, date navigation, grouping and homepage summary.
# No EventKit, SwiftData or SwiftUI runtime: Apple integration/rendering still needs Xcode.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/Butler" "$scratch/Tests/ButlerTests"
for file in HomeAgenda AgendaOverview ReminderSchedule; do
    ln -s "$root/Butler/Domain/$file.swift" "$scratch/Sources/Butler/$file.swift"
done
ln -s "$root/ButlerTests/AgendaOverviewTests.swift" "$scratch/Tests/ButlerTests/AgendaOverviewTests.swift"
python3 - "$root" "$scratch" <<'PY'
import pathlib, sys
root, scratch = map(pathlib.Path, sys.argv[1:])
def read(path): return (root / path).read_text()
# Unchanged value declarations and date formatting from Apple-dependent files.
values = "import Foundation\nstruct TimedReminder:" + read("Butler/Services/ReminderStore.swift").split("struct TimedReminder:", 1)[1].split("/// Task records are durable", 1)[0]
values += "extension Date {" + read("Butler/Design/Theme.swift").split("extension Date {", 1)[1]
values += "extension Date {" + read("Butler/Views/Home/HomeView.swift").split("extension Date {", 1)[1].split("/// Home:", 1)[0]
(scratch / "Sources/Butler/Values.swift").write_text(values)
PY
# Only the unexercised SwiftData-derived inventory input is a fixture; tests pass no lots.
cat > "$scratch/Sources/Butler/InventoryFixture.swift" <<'SWIFT'
import Foundation
enum LotDateKind { case packageExpiry, estimatedExpiry, plannedUseBy }
struct LotFacts {
    let id: UUID
    let name: String
    let quantity: Int
    let unit: String
    let storageLocation: String?
    let governingDate: Date?
    let governingDateKind: LotDateKind?
    let daysLeft: Int?
    let isRunningLow: Bool
    let needsDate: Bool
    let needsCompartment: Bool
    let dateStatusLabel: String
    let dateKindLabel: String
}
SWIFT
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ButlerAgendaCore", targets: [
    .target(name: "Butler", swiftSettings: [
        .defaultIsolation(MainActor.self),
        .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"])
    ]),
    .testTarget(name: "ButlerTests", dependencies: ["Butler"], swiftSettings: [
        .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"])
    ])
], swiftLanguageModes: [.v5])
SWIFT
swift test --package-path "$scratch"
