import XCTest
import AVFoundation
@testable import Butler

@MainActor
final class RealtimeSpeechTests: XCTestCase {
    func testRealtimeEndpointAndSessionMatchGatewayProtocol() throws {
        let config = try configuration()
        XCTAssertEqual(config.realtimeEndpoint.absoluteString, "wss://api.inferera.com/v1/realtime?intent=transcription&model=gpt-live-transcribe")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(RealtimeSpeechClient.sessionUpdate(model: config.model).utf8)) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24000)
        XCTAssertEqual((input["transcription"] as? [String: Any])?["model"] as? String, "gpt-live-transcribe")
    }

    func testOrderedAudioDeltasAndFinalCorrectionWithoutDuplication() async throws {
        let socket = TestSpeechSocket()
        let config = try configuration()
        let client = RealtimeSpeechClient(configuration: config, socket: socket)
        defer { client.cancel() }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        var heard: [String] = []
        client.start(model: config.model, audio: stream, onText: { heard.append($0) }, onFailure: { _ in XCTFail("unexpected error") })
        continuation.yield(Data(repeating: 1, count: 4800))
        continuation.yield(Data(repeating: 2, count: 4800))
        continuation.finish()
        let result = try await client.finish()
        XCTAssertEqual(result, "买一盒鸡蛋。")
        XCTAssertEqual(heard, ["买", "买一盒", "买一盒鸡蛋。"])
        XCTAssertEqual(socket.types, ["session.update", "input_audio_buffer.append", "input_audio_buffer.append", "input_audio_buffer.commit"])
        XCTAssertEqual(socket.audio, [Data(repeating: 1, count: 4800), Data(repeating: 2, count: 4800)])
    }

    func testConnectionCheckAuthenticatesWithoutUploadingAudio() async throws {
        let config = try configuration()
        let socket = TestSpeechSocket()
        try await RealtimeSpeechClient(configuration: config, socket: socket).checkConnection(model: config.model)
        XCTAssertEqual(socket.types, ["session.update"])
        XCTAssertTrue(socket.cancelled)
    }

    func testCancellationDiscardsLateTextAndStopsConnection() async throws {
        let config = try configuration()
        let socket = TestSpeechSocket()
        let client = RealtimeSpeechClient(configuration: config, socket: socket)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        var heard = ""
        client.start(model: config.model, audio: stream, onText: { heard = $0 }, onFailure: { _ in XCTFail("cancel isn't an error") })
        client.cancel()
        continuation.yield(Data(repeating: 0, count: 4800)); continuation.finish()
        socket.emit(["type": "conversation.item.input_audio_transcription.delta", "delta": "late"])
        await Task.yield()
        XCTAssertTrue(socket.cancelled)
        XCTAssertEqual(heard, "")
        XCTAssertFalse(socket.types.contains("input_audio_buffer.append"))
    }

    func testServiceRejectionIsSafeAndDoesNotDeliverPartialResult() async throws {
        let config = try configuration()
        let socket = TestSpeechSocket()
        socket.rejection = ["type": "error", "error": ["code": "insufficient_user_quota", "message": "private account SECRET"]]
        let client = RealtimeSpeechClient(configuration: config, socket: socket)
        defer { client.cancel() }
        do {
            try await client.checkConnection(model: config.model)
            XCTFail("must reject")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("额度不足"))
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
    }

    func testPCMConversionResamplesStereoTo24kMonoInt16() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        let converter = try RealtimePCMConverter(source: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<2 {
            for frame in 0..<4800 { buffer.floatChannelData![channel][frame] = 0.25 }
        }
        var total = Data()
        for _ in 0..<10 { total.append(try converter.convert(buffer)) }
        XCTAssertEqual(total.count % 2, 0)
        XCTAssertGreaterThan(total.count, 47000)
        XCTAssertLessThanOrEqual(total.count, 48000)
        XCTAssertTrue(total.contains(where: { $0 != 0 }))
    }

    private func configuration() throws -> CustomSpeechConfiguration {
        try .validated(baseURL: "https://api.inferera.com", model: "gpt-live-transcribe", apiKey: "fictional-key")
    }
}

@MainActor
private final class TestSpeechSocket: SpeechSocket {
    var statusCode: Int? = 101
    var types: [String] = []
    var audio: [Data] = []
    var cancelled = false
    var rejection: [String: Any]?
    private var messages: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    func resume() {}
    func send(_ text: String) async throws {
        guard !cancelled else { throw CancellationError() }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let type = object["type"] as! String
        types.append(type)
        switch type {
        case "session.update": emit(rejection ?? ["type": "session.updated"])
        case "input_audio_buffer.append":
            audio.append(Data(base64Encoded: object["audio"] as! String)!)
            emit(["type": "conversation.item.input_audio_transcription.delta", "delta": audio.count == 1 ? "买" : "一盒"])
        case "input_audio_buffer.commit": emit(["type": "conversation.item.input_audio_transcription.completed", "transcript": "买一盒鸡蛋。"])
        default: break
        }
    }
    func receive() async throws -> Data {
        if cancelled { throw CancellationError() }
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        if let waiter { self.waiter = nil; waiter.resume(returning: data) }
        else { messages.append(data) }
    }
    func cancel() {
        cancelled = true
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }
}
