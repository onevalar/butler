//
//  VoiceManager.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import Foundation
import Speech
import AVFoundation
import Observation

// MARK: - Voice State

enum VoiceState: Equatable {
    case idle
    case recording
    case processing
    case error(String)
}

// MARK: - Voice Manager

/// Handles microphone access and SFSpeechRecognizer
@MainActor
@Observable
final class VoiceManager: NSObject, SFSpeechRecognizerDelegate {
    
    // MARK: - Properties
    
    var state: VoiceState = .idle
    var transcribedText: String = ""
    
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // MARK: - Initialization
    
    override init() {
        // Force Chinese locale for this demo
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        super.init()
        self.speechRecognizer?.delegate = self
    }

    /// Nothing to clean up; keep deinit off the MainActor executor to avoid a Swift 6.2 runtime crash
    /// (swift_task_deinitOnExecutor frees an unallocated TaskLocal scope when released on the main thread).
    nonisolated deinit {}
    
    // MARK: - Public API
    
    /// Request authorization for Speech and Microphone
    func requestAuthorization() async -> Bool {
        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        
        let micAuth = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        
        return speechAuth && micAuth
    }
    
    /// Start listening
    func startRecording(requiresOnDeviceRecognition: Bool = false) throws {
        // Cancel existing tasks
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        // Configure Session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        guard !requiresOnDeviceRecognition || speechRecognizer?.supportsOnDeviceRecognition == true else {
            state = .error("此设备未提供中文离线语音识别，请使用文字输入。")
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw VoiceError.onDeviceRecognitionUnavailable
        }

        // Create Request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw VoiceError.setupFailed
        }
        
        // M2 requires local recognition; legacy remains local-first with server fallback if unavailable.
        recognitionRequest.requiresOnDeviceRecognition =
            requiresOnDeviceRecognition || speechRecognizer?.supportsOnDeviceRecognition == true
        
        // Setup Input Node
        let inputNode = audioEngine.inputNode
        
        // Start Task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            var isFinal = false
            
            if let result = result {
                self.transcribedText = result.bestTranscription.formattedString
                isFinal = result.isFinal
            }
            
            if error != nil || isFinal {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
                
                if let error {
                    print("Voice Error: \(error)")
                    // Don't show "Cancelled" as error
                    if (error as NSError).code != 203 { // 203 = Retry
                         self.state = .idle
                    }
                }
            }
        }
        
        // Audio Engine Tapping
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        state = .recording
        transcribedText = ""
    }
    
    /// Stops local speech recognition and returns text without invoking the legacy NLP parser.
    func stopRecordingAndTranscribe() async -> String? {
        // Stop Audio
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        
        state = .processing
        
        // Wait a slight moment for final entry
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        let finalText = transcribedText
        
        // If empty, abort
        if finalText.isEmpty {
            state = .idle
            return nil
        }
        
        state = .idle
        return finalText
    }
    
    /// Cancel current session
    func cancel() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        state = .idle
        transcribedText = ""
    }
}

// MARK: - Errors

enum VoiceError: Error, LocalizedError {
    case setupFailed
    case onDeviceRecognitionUnavailable

    var errorDescription: String? {
        switch self {
        case .setupFailed: return "语音识别启动失败。"
        case .onDeviceRecognitionUnavailable: return "此设备未提供中文离线语音识别，请使用文字输入。"
        }
    }
}
