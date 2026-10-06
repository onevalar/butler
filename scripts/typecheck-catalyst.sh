#!/usr/bin/env bash
set -euo pipefail
# Type-checks the whole Butler app module against the macOS SDK's Mac Catalyst (iOSSupport) frameworks.
# Needs only Xcode, not the iOS platform download. It is a compile check, not a build: no linking, no
# tests, no Swift packages (ChatMarkdownText, the only MarkdownUI user, is replaced by a plain stand-in),
# and AlarmKitDevice is left out because AlarmKit does not exist on Catalyst. Diagnostics that only mean
# "this iOS API is unavailable on Catalyst" are expected and filtered; anything else fails the script.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
sdk="$(xcrun --show-sdk-path --sdk macosx)"
cat > "$scratch/Stubs.swift" <<'SWIFT'
import SwiftUI
struct ChatMarkdownText: View { let text: String; var body: some View { Text(text) } }
extension AlarmStore { static var shared: AlarmStore { fatalError("AlarmKit is unavailable on Mac Catalyst") } }
SWIFT
cd "$root"
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Butler ButlerAlarmShared ButlerShareShared ButlerWidgetShared -name '*.swift' \
        ! -name ChatMarkdownText.swift ! -name AlarmKitDevice.swift | sort)
set +e
xcrun swiftc -typecheck -continue-building-after-errors -module-name Butler \
    -target arm64-apple-ios26.2-macabi -sdk "$sdk" \
    -Fsystem "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/lib/swift" \
    -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -D DEBUG "$scratch/Stubs.swift" "${sources[@]}" > "$scratch/log" 2>&1
set -e
diagnostics="$(grep -E '\.swift:[0-9]+:[0-9]+: (error|warning):' "$scratch/log" || true)"
expected="$(grep -E 'unavailable|DataScannerViewControllerDelegate' <<< "$diagnostics" || true)"
unexpected="$(grep -vE 'unavailable|DataScannerViewControllerDelegate' <<< "$diagnostics" | grep -v '^$' || true)"
echo "Checked ${#sources[@]} files; $(grep -c . <<< "$expected" || true) expected Catalyst-only diagnostics."
if [ -n "$unexpected" ]; then
    echo "Unexpected diagnostics:"
    echo "$unexpected"
    exit 1
fi
echo "No other errors or warnings."
