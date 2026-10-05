import Foundation

enum CaptureMode: String, Codable, CaseIterable, Sendable {
  case typing, voice
}

struct CaptureRecord: Codable, Identifiable, Equatable, Sendable {
  var id: UUID
  var receivedAt: Date
  var mode: CaptureMode
  var text: String
  var savedAt: Date?
}

struct CaptureFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Private app-container storage. No App Group, production database, or cloud account.
/// Publish the image and metadata together; subsequent typing only rewrites metadata.
struct CaptureStore {
  let root: URL

  func records() throws -> [CaptureRecord] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { UUID(uuidString: $0.lastPathComponent) != nil }
      .map { folder in
        let record = try JSONDecoder().decode(
          CaptureRecord.self, from: Data(contentsOf: folder.appendingPathComponent("record.json")))
        guard record.id.uuidString == folder.lastPathComponent,
          FileManager.default.fileExists(atPath: folder.appendingPathComponent("image.jpg").path)
        else {
          throw CaptureFailure(message: "实验记录不完整，已停止接收新截图，避免覆盖。")
        }
        return record
      }
      .sorted { $0.receivedAt > $1.receivedAt }
  }

  func create(image: Data, mode: CaptureMode) throws -> CaptureRecord {
    guard !(try records()).contains(where: { $0.savedAt == nil }) else {
      throw CaptureFailure(message: "还有一条未完成的实验草稿。请先保存或删除它，再重新截图；本次没有覆盖旧内容。")
    }
    guard !image.isEmpty, image.count <= 4 * 1024 * 1024 else {
      throw CaptureFailure(message: "截图为空或过大，本次没有保存。")
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #if os(iOS)
      var directory = root
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
    #endif
    let record = CaptureRecord(id: UUID(), receivedAt: Date(), mode: mode, text: "")
    let staging = root.appendingPathComponent(".\(record.id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: staging) }
    try image.write(to: staging.appendingPathComponent("image.jpg"), options: .atomic)
    try JSONEncoder().encode(record).write(
      to: staging.appendingPathComponent("record.json"), options: .atomic)
    try FileManager.default.moveItem(at: staging, to: folder(record.id))
    return record
  }

  func update(_ record: CaptureRecord) throws {
    try JSONEncoder().encode(record).write(
      to: folder(record.id).appendingPathComponent("record.json"), options: .atomic)
  }

  func finish(_ record: CaptureRecord) throws -> CaptureRecord {
    guard !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CaptureFailure(message: "请先说明这次想做什么。实验不会替你猜测意图。")
    }
    var saved = record
    saved.savedAt = Date()
    try update(saved)
    return saved
  }

  func image(_ id: UUID) throws -> Data {
    try Data(contentsOf: folder(id).appendingPathComponent("image.jpg"))
  }

  func delete(_ id: UUID) throws {
    try FileManager.default.removeItem(at: folder(id))
  }

  private func folder(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }
}
