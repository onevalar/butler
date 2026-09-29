import AVFoundation

/// Owned by a single audio tap; converts native microphone samples into the gateway's
/// PCM16 little-endian, 24 kHz, mono wire format. No AVAudioPCMBuffer crosses actor boundaries.
final class RealtimePCMConverter: @unchecked Sendable {
    nonisolated deinit {}
    nonisolated private let converter: AVAudioConverter
    nonisolated private let target: AVAudioFormat
    nonisolated init(source: AVAudioFormat) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw CocoaError(.coderInvalidValue) }
        self.target = target
        self.converter = converter
    }
    nonisolated func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw CocoaError(.coderInvalidValue) }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let samples = output.int16ChannelData?[0] else { throw CocoaError(.coderInvalidValue) }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
