#!/usr/bin/env bash
set -euo pipefail
# Linux-compatible W03/W05 checks, not a substitute for an Xcode app build.
# Compile the actual operation codec and log writer. Extract ONLY unchanged value
# declarations from Apple-dependent files; SwiftData persistence and ItemProfile
# behavior are deliberately outside this harness's scope.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/Butler" "$scratch/Tests/ButlerTests"
ln -s "$root/Butler/Domain/InventoryOperationPlan.swift" "$scratch/Sources/Butler/InventoryOperationPlan.swift"
ln -s "$root/Butler/Services/Agent/ChatDiagnostics.swift" "$scratch/Sources/Butler/ChatDiagnostics.swift"
ln -s "$root/ButlerTests/InventoryOperationCodingTests.swift" "$scratch/Tests/ButlerTests/InventoryOperationCodingTests.swift"
ln -s "$root/ButlerTests/ChatDiagnosticsTests.swift" "$scratch/Tests/ButlerTests/ChatDiagnosticsTests.swift"
python3 - "$root" "$scratch" <<'PY'
import pathlib
import re
import sys

root, scratch = map(pathlib.Path, sys.argv[1:])
parts = ["import Foundation\n"]
for path, name in [
    ("Butler/Models/V2/FieldEvidence.swift", "EvidenceSourceKind"),
    ("Butler/Models/V2/InventoryLot.swift", "InventoryLotState"),
]:
    source = (root / path).read_text()
    declaration = re.search(r"enum " + name + r":[^}]+\}", source)
    assert declaration, f"Missing value declaration: {name}"
    parts.append(declaration.group())
profile = (root / "Butler/Domain/ItemProfile.swift").read_text()
parts.append(profile.split("struct ItemProfile:")[0].removeprefix("import Foundation\n"))
parts.append("struct ItemProfile:" + profile.split("struct ItemProfile:")[1].split("    var availabilityLabel:")[0] + "}\n")
# Tests use an explicit temporary log destination, never this app-path fixture.
parts.append("enum BackupService { nonisolated static var supportDirectory: URL? { nil } }\n")
(scratch / "Sources/Butler/ValueDeclarations.swift").write_text("\n".join(parts))
PY
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ButlerWarningCore", targets: [
    .target(name: "Butler", swiftSettings: [
        .defaultIsolation(MainActor.self),
        .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"])
    ]),
    // Linux XCTest's required initializer is nonisolated; test methods explicitly
    // opt into MainActor where needed. The production target keeps default isolation.
    .testTarget(name: "ButlerTests", dependencies: ["Butler"], swiftSettings: [
        .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"])
    ])
], swiftLanguageModes: [.v5])
SWIFT
swift test --package-path "$scratch"
