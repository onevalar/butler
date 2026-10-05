@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech
import UIKit

/// Deliberately device-only for the lab: no custom provider or server fallback.
@MainActor @Observable
final class CaptureSpeech {
  enum State { case idle, preparing, listening, finishing }
  private(set) var state: State = .idle
  var error: String?
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognition: SFSpeechRecognitionTask?
  private var sessionID: UUID?
  private var hasTap = false
  private var audioActive = false

  func start(base: String, onText: @escaping @MainActor @Sendable (String) -> Void) async {
    guard state == .idle, !Task.isCancelled else { return }
    let id = UUID()
    sessionID = id
    state = .preparing
    error = nil
    let speech = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { @Sendable status in
        continuation.resume(returning: status)
      }
    }
    guard sessionID == id, !Task.isCancelled else { return }
    let microphone = await AVAudioApplication.requestRecordPermission()
    guard sessionID == id, !Task.isCancelled else { return }
    guard speech == .authorized, microphone else {
      cancel()
      error = "未获得麦克风或语音识别权限。可以直接打字，或在系统设置中允许。"
      return
    }
    guard UIApplication.shared.applicationState == .active,
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
      recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
    else {
      cancel()
      error = "当前无法启动设备端中文识别。回到此页再试，或直接打字；实验不会切换到云端识别。"
      return
    }
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
      try audio.setActive(true)
      audioActive = true
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.requiresOnDeviceRecognition = true
      self.request = request
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw CaptureFailure(message: "麦克风当前不可用。")
      }
      // The SDK's tap callback is not Sendable-annotated and runs on an audio thread.
      // Mark it explicitly so it cannot inherit this method's MainActor isolation.
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
        request.append(buffer)
      }
      hasTap = true
      let prefix = base.isEmpty ? "" : base + "\n"
      recognition = recognizer.recognitionTask(with: request) {
        @Sendable [weak self] result, failure in
        let text = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal ?? false
        let failed = failure != nil
        Task { @MainActor in
          guard let self, self.sessionID == id else { return }
          if let text, !text.isEmpty { onText(prefix + text) }
          if isFinal || failed {
            let wasFinishing = self.state == .finishing
            self.cancel()
            if failed && !wasFinishing {
              self.error = "识别已停止，已识别的文字仍保留。请核对后保存，或改用打字。"
            }
          }
        }
      }
      engine.prepare()
      try engine.start()
      state = .listening
    } catch {
      cancel()
      self.error = "语音未能启动，请改用打字：\(error.localizedDescription)"
    }
  }

  func stop() async {
    guard state == .listening, let id = sessionID else {
      cancel()
      return
    }
    state = .finishing
    stopMicrophone()
    request?.endAudio()
    // Allow a final result, but never block the user indefinitely.
    try? await Task.sleep(for: .seconds(1.5))
    if sessionID == id { cancel() }
  }

  func cancel() {
    sessionID = nil  // Ignore any late callbacks from this recording.
    stopMicrophone()
    recognition?.cancel()
    recognition = nil
    request = nil
    state = .idle
  }

  private func stopMicrophone() {
    engine.stop()
    if hasTap {
      engine.inputNode.removeTap(onBus: 0)
      hasTap = false
    }
    if audioActive {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      audioActive = false
    }
  }
}
