import Foundation
import Observation

@MainActor @Observable
final class CaptureModel {
  static let shared = CaptureModel(
    store: CaptureStore(
      root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CaptureLab", isDirectory: true)
    ))
  let store: CaptureStore
  var draft: CaptureRecord?
  var saved: [CaptureRecord] = []
  var autoStartID: UUID?
  var error: String?
  var notice: String?
  private var loadFailed = false

  init(store: CaptureStore) {
    self.store = store
    do {
      let records = try store.records()
      draft = records.first { $0.savedAt == nil }
      saved = records.filter { $0.savedAt != nil }
      // Restored drafts must never start the microphone by themselves.
    } catch {
      loadFailed = true
      self.error = "读取实验记录失败，已停止接收新截图。请保留数据并检查：\(error.localizedDescription)"
    }
  }

  func receive(_ image: Data, mode: CaptureMode) throws {
    guard !loadFailed else { throw CaptureFailure(message: error ?? "无法读取实验记录。") }
    let record = try store.create(image: image, mode: mode)
    draft = record
    autoStartID = record.id
    error = nil
    notice = nil
  }

  func edit(_ text: String, id: UUID) {
    guard var record = draft, record.id == id else { return }
    record.text = text
    draft = record  // Keep the input available for retry even if disk writes fail.
    do {
      try store.update(record)
      error = nil
    } catch {
      self.error = "草稿尚未保存，请不要退出。可点保存重试：\(error.localizedDescription)"
    }
  }

  func finish() {
    guard let draft else { return }
    do {
      let record = try store.finish(draft)
      saved.insert(record, at: 0)
      self.draft = nil
      autoStartID = nil
      error = nil
      notice = "已保存到本机实验记录，未执行任何任务。可用底部横滑或应用切换器返回原 App。"
    } catch {
      self.error = "没有完成保存：\(error.localizedDescription)"
    }
  }

  func delete(_ id: UUID) {
    do {
      try store.delete(id)
      if draft?.id == id {
        draft = nil
        autoStartID = nil
      }
      saved.removeAll { $0.id == id }
      error = nil
    } catch {
      self.error = "没有删除成功：\(error.localizedDescription)"
    }
  }
}
