import AppIntents
import ImageIO
import UIKit
import UniformTypeIdentifiers

extension CaptureMode: AppEnum {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "录入方式"
  static let caseDisplayRepresentations: [CaptureMode: DisplayRepresentation] = [
    .typing: "打字", .voice: "语音",
  ]
}

struct ReceiveCaptureIntent: AppIntent {
  static let title: LocalizedStringResource = "接收截图并开始实验录入"
  static let description = IntentDescription(
    "仅把传入的截图和自由输入保存到采集实验 App，不执行任务，也不写入正式版小当家。请先用系统“截屏”动作取得图片。")
  static let supportedModes: IntentModes = .foreground
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

  @Parameter(title: "截图", supportedContentTypes: [.image]) var screenshot: IntentFile
  @Parameter(title: "录入方式", default: .typing) var mode: CaptureMode
  static var parameterSummary: some ParameterSummary {
    Summary("接收\(\.$screenshot)并以\(\.$mode)录入")
  }

  @MainActor func perform() async throws -> some IntentResult {
    let data = screenshot.data
    guard !data.isEmpty, data.count <= 20 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1600,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary),
      let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    else {
      throw CaptureFailure(message: "没有收到可读取的截图。请把系统“截屏”动作的结果直接传给本动作，不要使用“最新照片”。")
    }
    try Task.checkCancellation()
    try CaptureModel.shared.receive(jpeg, mode: mode)
    return .result()
  }
}
