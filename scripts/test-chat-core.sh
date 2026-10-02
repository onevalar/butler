#!/usr/bin/env bash
set -euo pipefail
# Exercises actual file commit/recovery and reply presentation state, not SwiftUI, SwiftData,
# model requests, or brief hashing. The full application still requires Xcode.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/Butler" "$scratch/Tests/ButlerTests"
ln -s "$root/ButlerTests/ChatSendPersistenceTests.swift" "$scratch/Tests/ButlerTests/ChatSendPersistenceTests.swift"
ln -s "$root/ButlerTests/ChatConfirmationTests.swift" "$scratch/Tests/ButlerTests/ChatConfirmationTests.swift"
ln -s "$root/ButlerTests/ChatReplyPresentationTests.swift" "$scratch/Tests/ButlerTests/ChatReplyPresentationTests.swift"
ln -s "$root/ButlerTests/ChatScrollPolicyTests.swift" "$scratch/Tests/ButlerTests/ChatScrollPolicyTests.swift"
ln -s "$root/ButlerTests/ChatCollectionPersistenceTests.swift" "$scratch/Tests/ButlerTests/ChatCollectionPersistenceTests.swift"
ln -s "$root/ButlerTests/ChatReplyObservationTests.swift" "$scratch/Tests/ButlerTests/ChatReplyObservationTests.swift"
ln -s "$root/Butler/Domain/ConfirmationResult.swift" "$scratch/Sources/Butler/ConfirmationResult.swift"
ln -s "$root/Butler/Services/Agent/ChatReplyProgress.swift" "$scratch/Sources/Butler/ChatReplyProgress.swift"
ln -s "$root/Butler/Views/Agent/ChatScrollPolicy.swift" "$scratch/Sources/Butler/ChatScrollPolicy.swift"
python3 - "$root" "$scratch" <<'PY'
import pathlib
import sys
root, scratch = map(pathlib.Path, sys.argv[1:])
parts = ["import Foundation\n"]
for path, start, end in [
    ("Butler/Services/Agent/ButlerChat.swift", "struct ChatTurn:", "/// Older conversation"),
    ("Butler/Services/Agent/ItemTools.swift", "struct ItemCollection:", "extension ButlerTools"),
    ("Butler/Domain/SyncRecord.swift", "struct SyncFailure:", "struct SyncCleanupNotStarted:"),
    ("Butler/Services/ChatSyncData.swift", "struct SyncedChatTurn:", "/// A separate opt-in stream:"),
]:
    source = (root / path).read_text()
    parts.append(start + source.split(start, 1)[1].split(end, 1)[0])
source = (root / "Butler/Services/Agent/ChatScope.swift").read_text()
parts.append("enum ChatScope:" + source.split("enum ChatScope:", 1)[1])
# Only .general and .task storage is tested here. The unused brief identity needs
# a value type on Linux, where Apple's CryptoKit is not available.
parts.append('struct BriefConversation: Hashable, Codable { var key: String }')
(scratch / "Sources/Butler/ChatStorage.swift").write_text("\n".join(parts))
PY
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ButlerChatCore", targets: [
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
