import Foundation
import Testing

@testable import CaptureLabCore

struct CaptureStoreTests {
  private func withStore(_ test: (CaptureStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try test(CaptureStore(root: root))
  }

  @Test func unfinishedCaptureRejectsSecondImageAcrossReload() throws {
    try withStore { store in
      var first = try store.create(image: Data([0x11, 0x32, 0x56]), mode: .voice)
      first.text = "不是记账，帮我对比尺寸\n不要购买"
      try store.update(first)
      let reopened = CaptureStore(root: store.root)
      #expect(throws: CaptureFailure.self) {
        try reopened.create(image: Data([0xFA, 0xCE]), mode: .typing)
      }
      #expect(try reopened.records() == [first])
      #expect(try reopened.image(first.id) == Data([0x11, 0x32, 0x56]))
    }
  }

  @Test func finishKeepsIntentAndImagePairedAndAllowsNextCapture() throws {
    try withStore { store in
      var first = try store.create(image: Data([1, 5, 9]), mode: .typing)
      first.text = "\n提醒我七天后退货，不要记录库存  "
      let saved = try store.finish(first)
      let second = try store.create(image: Data([2, 4]), mode: .voice)
      let reloaded = try CaptureStore(root: store.root).records()
      #expect(reloaded.count == 2)
      #expect(reloaded.first(where: { $0.id == first.id })?.text == "\n提醒我七天后退货，不要记录库存  ")
      #expect(saved.savedAt != nil)
      #expect(second.savedAt == nil && second.text.isEmpty && second.mode == .voice)
      #expect(try store.image(first.id) == Data([1, 5, 9]))
      #expect(try store.image(second.id) == Data([2, 4]))
      try store.delete(second.id)
      #expect(try store.records() == [saved])
      #expect(
        !FileManager.default.fileExists(
          atPath: store.root.appendingPathComponent(second.id.uuidString).path))
    }
  }

  @Test func blankIntentDoesNotBecomeACompletedRecord() throws {
    try withStore { store in
      var draft = try store.create(image: Data([3]), mode: .typing)
      draft.text = " \n\t　"
      #expect(throws: CaptureFailure.self) { try store.finish(draft) }
      #expect(try store.records().first?.savedAt == nil)
    }
  }

  @Test func emptyAndOversizedImagesNeverPublish() throws {
    try withStore { store in
      for image in [Data(), Data(repeating: 7, count: 4 * 1024 * 1024 + 1)] {
        #expect(throws: CaptureFailure.self) { try store.create(image: image, mode: .typing) }
        #expect(try store.records().isEmpty)
      }
      let boundary = Data(repeating: 8, count: 4 * 1024 * 1024)
      let record = try store.create(image: boundary, mode: .voice)
      #expect(try store.image(record.id) == boundary)
    }
  }

  @Test func interruptedStagingIsNotPublishedAndCorruptionIsNotSilentlyIgnored() throws {
    try withStore { store in
      let unfinished = store.root.appendingPathComponent(".\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
      try Data([0xFF]).write(to: unfinished.appendingPathComponent("image.jpg"))
      #expect(try store.records().isEmpty)
      let record = try store.create(image: Data([5]), mode: .typing)
      let metadata = store.root.appendingPathComponent(record.id.uuidString).appendingPathComponent(
        "record.json")
      try Data("broken json".utf8).write(to: metadata)
      #expect(throws: (any Error).self) { try store.records() }
      #expect(throws: (any Error).self) { try store.create(image: Data([7]), mode: .voice) }
      #expect(try store.image(record.id) == Data([5]))
    }
  }

  @Test @MainActor func modelRestoresWithoutStartingMicrophoneAndRejectsLateEdits() throws {
    try withStore { store in
      let model = CaptureModel(store: store)
      try model.receive(Data([1, 9]), mode: .voice)
      let firstID = try #require(model.draft?.id)
      #expect(model.autoStartID == firstID)
      model.edit("保留中文意图", id: firstID)
      let restored = CaptureModel(store: store)
      #expect(restored.draft?.text == "保留中文意图")
      #expect(restored.autoStartID == nil)
      restored.finish()
      try restored.receive(Data([6, 2]), mode: .typing)
      restored.edit("上一段语音的迟到结果", id: firstID)
      #expect(restored.draft?.text == "")
      #expect(restored.saved.count == 1)
      #expect(restored.saved.first?.text == "保留中文意图")
    }
  }

  @Test @MainActor func failedSaveKeepsDraftForRetryInsteadOfClaimingSuccess() throws {
    try withStore { store in
      let model = CaptureModel(store: store)
      try model.receive(Data([3, 7]), mode: .typing)
      let id = try #require(model.draft?.id)
      let metadata = store.root.appendingPathComponent(id.uuidString).appendingPathComponent(
        "record.json")
      let original = try Data(contentsOf: metadata)
      try FileManager.default.removeItem(at: metadata)
      try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
      model.edit("不要丢掉我刚输入的话", id: id)
      model.finish()
      #expect(model.error != nil && model.notice == nil && model.saved.isEmpty)
      #expect(model.draft?.text == "不要丢掉我刚输入的话")
      #expect(try store.image(id) == Data([3, 7]))
      try FileManager.default.removeItem(at: metadata)
      try original.write(to: metadata)
      model.finish()
      #expect(model.draft == nil && model.error == nil && model.saved.count == 1)
      #expect(try store.records().first?.text == "不要丢掉我刚输入的话")
    }
  }
}
