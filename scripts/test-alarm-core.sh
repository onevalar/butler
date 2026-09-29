#!/usr/bin/env bash
set -euo pipefail
# Runs the actual Foundation-only alarm journal and tests without pretending to test AlarmKit.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/Butler" "$scratch/Tests/ButlerTests"
ln -s "$root/Butler/Domain/ButlerAlarm.swift" "$scratch/Sources/Butler/ButlerAlarm.swift"
ln -s "$root/Butler/Services/AlarmStore.swift" "$scratch/Sources/Butler/AlarmStore.swift"
ln -s "$root/ButlerTests/AlarmStoreTests.swift" "$scratch/Tests/ButlerTests/AlarmStoreTests.swift"
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ButlerAlarmCore", targets: [
    .target(name: "Butler", swiftSettings: [.defaultIsolation(MainActor.self)]),
    .testTarget(name: "ButlerTests", dependencies: ["Butler"])
], swiftLanguageModes: [.v5])
SWIFT
swift test --package-path "$scratch"
