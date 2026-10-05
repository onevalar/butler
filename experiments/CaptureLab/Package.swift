// swift-tools-version: 6.2
import PackageDescription

// Tests the actual storage and handoff model; the iOS UI/Speech/AppIntent need Xcode.
let package = Package(
  name: "CaptureLabCore",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "CaptureLabCore", path: ".",
      exclude: [
        "App/CaptureLabApp.swift", "App/CaptureIntent.swift", "App/CaptureSpeech.swift",
        "Tests", "CaptureLab.xcodeproj", "CaptureLab.xcconfig", "README.md",
      ], sources: ["Core", "App/CaptureModel.swift"],
      swiftSettings: [
        .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"])
      ]),
    .testTarget(name: "CaptureLabTests", dependencies: ["CaptureLabCore"], path: "Tests"),
  ],
  swiftLanguageModes: [.v5]
)
