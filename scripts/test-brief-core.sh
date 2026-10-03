#!/usr/bin/env bash
set -euo pipefail
# Executes the actual paging, read-only dispatch, tool loop, parsing, signatures and service lifecycle.
# Apple stores, network transport, candidate construction and SwiftUI still need the iOS test host.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/Butler" "$scratch/Tests/ButlerTests"
for file in Butler/Domain/BriefContext.swift Butler/Domain/DailyBrief.swift \
    Butler/Services/Agent/ToolConversationLoop.swift Butler/Services/Agent/PrefetchedToolResult.swift \
    Butler/Services/Agent/ChatDiagnostics.swift; do
    ln -s "$root/$file" "$scratch/Sources/Butler/$(basename "$file")"
done
ln -s "$root/ButlerTests/BriefReasoningTests.swift" "$scratch/Tests/ButlerTests/BriefReasoningTests.swift"
python3 - "$root" "$scratch" <<'PY'
import pathlib, sys
root, scratch = map(pathlib.Path, sys.argv[1:])
def read(path): return (root / path).read_text()
brief = read("Butler/Domain/ButlerBrief.swift")
# Navigation-only properties depend on the iOS conversation/agenda types and are not exercised here.
brief = brief.split("    /// The conversation that belongs", 1)[0] + "}\n\n/// What a button does" + brief.split("/// What a button does", 1)[1]
# Keep the actual signature; constructing candidates from SwiftData facts is covered by iOS tests.
before, rest = brief.split("enum BriefCandidates {", 1)
brief = before + "enum BriefCandidates {\n    static func signature(" + rest.split("    static func signature(", 1)[1]
(scratch / "Sources/Butler/ButlerBrief.swift").write_text(brief)
service = read("Butler/Services/BriefService.swift")
service = service.split("/// The same model", 1)[0] + "/// Keeps" + service.split("/// Keeps", 1)[1].split("/// Carries out", 1)[0]
(scratch / "Sources/Butler/BriefService.swift").write_text(service.replace("import SwiftData\n", ""))
agent = read("Butler/Services/LocalAgent.swift")
values = "import Foundation\n" + "struct LocalToolCall:" + agent.split("struct LocalToolCall:", 1)[1].split("/// A small tool loop", 1)[0]
state = read("Butler/Models/V2/InventoryLot.swift")
values += "enum InventoryLotState:" + state.split("enum InventoryLotState:", 1)[1].split("/// One owned batch", 1)[0]
values += "extension Date {" + read("Butler/Services/Agent/ButlerTools.swift").rsplit("extension Date {", 1)[1]
weather = read("Butler/Services/WeatherStore.swift")
values += "struct WeatherPlace:" + weather.split("struct WeatherPlace:", 1)[1].split("@MainActor @Observable", 1)[0]
# Only the WeatherKit localization boundary is substituted, never the brief behavior under test.
values += 'enum WeatherCondition { static func chineseLabel(for value: String) -> String { value } }\n'
values += 'enum BackupService { nonisolated static var supportDirectory: URL? { nil } }\n'
(scratch / "Sources/Butler/Values.swift").write_text(values)
PY
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ButlerBriefCore", targets: [
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
