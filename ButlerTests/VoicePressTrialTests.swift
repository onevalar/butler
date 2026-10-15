import XCTest
@testable import Butler

@MainActor
final class VoicePressTrialTests: XCTestCase {
    func testRecorderSpecificFinalizationTimeoutIsUsedAndFailureDoesNotSend() async {
        let recorder = Recorder()
        recorder.finalizationTimeout = .milliseconds(30)
        let interaction = make(recorder, Feedback())
        var sends = 0
        interaction.begin(onTranscript: { _ in sends += 1 })
        await wait { recorder.starts.count == 1 }
        recorder.ready(0)
        await wait { interaction.phase == .recording }
        interaction.release()
        await wait { recorder.finishes.count == 1 }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(interaction.phase, .idle)
        XCTAssertNotNil(interaction.issue)
        recorder.finish(0, text: "late remote result")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(sends, 0)
    }

    func testServiceErrorDoesNotSendPartialText() async {
        let recorder = Recorder()
        let interaction = make(recorder, Feedback())
        var sends = 0
        interaction.begin(onTranscript: { _ in sends += 1 })
        await wait { recorder.starts.count == 1 }
        recorder.ready(0)
        await wait { interaction.phase == .recording }
        interaction.release()
        await wait { recorder.finishes.count == 1 }
        recorder.error = "API Key 无效"
        recorder.finish(0, text: "partial")
        await wait { interaction.phase == .idle }
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(interaction.issue, "API Key 无效")
    }

    func testShortPressOpensTypingOnceWithoutStartingSpeech() async {
        let recorder = Recorder()
        let feedback = Feedback()
        var time = 10.0
        let interaction = VoicePressInteraction(recorder: recorder, feedback: feedback, now: { time })
        var taps = 0, voices = 0, sends = 0
        interaction.begin(onTap: { taps += 1 }, onVoice: { voices += 1 }, onTranscript: { _ in sends += 1 })
        time += 0.15
        interaction.release()
        interaction.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(voices, 0)
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(recorder.starts.isEmpty)
        XCTAssertEqual(interaction.phase, .idle)
        XCTAssertNil(interaction.issue)
    }

    func testLongPressSendsOnceAndNeverOpensTyping() async {
        let recorder = Recorder()
        let interaction = make(recorder, Feedback())
        var taps = 0, voices = 0
        var messages: [String] = []
        interaction.begin(onTap: { taps += 1 }, onVoice: { voices += 1 }, onTranscript: { messages.append($0) })
        await wait { recorder.starts.count == 1 }
        recorder.ready(0)
        await wait { interaction.phase == .recording }
        interaction.release()
        interaction.release()
        await wait { recorder.finishes.count == 1 }
        recorder.finish(0, text: "  买一盒鸡蛋  ")
        await wait { interaction.phase == .idle }
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(voices, 1)
        XCTAssertEqual(messages, ["买一盒鸡蛋"])
    }

    func testReleaseAtHoldThresholdNeverFallsBackToTypingEvenIfStartTaskIsLate() {
        let recorder = Recorder()
        var time = 0.0
        let interaction = VoicePressInteraction(recorder: recorder, feedback: Feedback(), now: { time })
        var taps = 0
        interaction.begin(onTap: { taps += 1 })
        time = 0.3
        interaction.release()
        XCTAssertEqual(taps, 0)
        XCTAssertNotNil(interaction.issue)
    }

    func testSidewaysAndDownwardRecordingDragsDoNotCancelOrDuplicateDelivery() async {
        let recorder = Recorder()
        let feedback = Feedback()
        let interaction = make(recorder, feedback)
        var messages: [String] = []
        interaction.begin(onTranscript: { messages.append($0) })
        await wait { recorder.starts.count == 1 }
        recorder.ready(0)
        await wait { interaction.phase == .recording }
        for point in [CGSize(width: -200, height: 0), CGSize(width: 200, height: 20), .zero] {
            interaction.move(translation: point)
            XCTAssertFalse(interaction.cancelling)
            XCTAssertEqual(interaction.phase, .recording)
        }
        XCTAssertEqual(feedback.boundaries, 0)
        interaction.move(translation: CGSize(width: 120, height: -100))
        XCTAssertTrue(interaction.cancelling)
        interaction.move(translation: CGSize(width: -90, height: -50))
        XCTAssertFalse(interaction.cancelling)
        XCTAssertEqual(feedback.boundaries, 2)
        interaction.release()
        await wait { recorder.finishes.count == 1 }
        recorder.finish(0, text: "测试侧拖后发送")
        await wait { interaction.phase == .idle }
        XCTAssertEqual(messages, ["测试侧拖后发送"])
    }

    func testShortDragIsNotMistakenForTapEvenAfterReturningToOrigin() {
        let interaction = VoicePressInteraction(recorder: Recorder(), feedback: Feedback(), now: { 0 })
        var taps = 0
        interaction.begin(onTap: { taps += 1 })
        interaction.move(translation: CGSize(width: 30, height: 0))
        interaction.move(translation: .zero)
        interaction.release()
        XCTAssertEqual(taps, 0)
        XCTAssertNil(interaction.issue)
    }

    func testCancelledHoldDoesNotSendOrOpenTypingAndNextTapWorks() async {
        let recorder = Recorder()
        let interaction = VoicePressInteraction(recorder: recorder, feedback: Feedback(), holdDelay: .milliseconds(5))
        var taps = 0, sends = 0
        interaction.begin(onTap: { taps += 1 }, onTranscript: { _ in sends += 1 })
        try? await Task.sleep(for: .milliseconds(20))
        await wait { recorder.starts.count == 1 }
        recorder.ready(0)
        await wait { interaction.phase == .recording }
        interaction.move(y: -100)
        interaction.release()
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(sends, 0)
        interaction.begin(onTap: { taps += 1 }, onTranscript: { _ in sends += 1 })
        interaction.release()
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(sends, 0)
    }

    func testCommittedHoldWithNoWordsDoesNotOpenTypingOrSendEmptyMessage() async {
        let recorder = Recorder()
        let interaction = make(recorder, Feedback())
        var taps = 0, sends = 0
        interaction.begin(onTap: { taps += 1 }, onTranscript: { _ in sends += 1 })
        await wait { recorder.starts.count == 1 }
        recorder.ready(0)
        await wait { interaction.phase == .recording }
        interaction.release()
        await wait { recorder.finishes.count == 1 }
        recorder.finish(0, text: "   ")
        await wait { interaction.phase == .idle }
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(sends, 0)
        XCTAssertNotNil(interaction.issue)
    }

    func testSystemCancellationNeverOpensTyping() {
        let interaction = VoicePressInteraction(recorder: Recorder(), feedback: Feedback())
        var taps = 0
        interaction.begin(onTap: { taps += 1 })
        interaction.cancel()
        interaction.release()
        XCTAssertEqual(taps, 0)
    }

    func testFeedbackStartsSynchronouslyBeforeHoldOrMicrophone() {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = make(recorder, feedback)
        trial.begin()
        XCTAssertEqual(feedback.begins, 1)
        XCTAssertTrue(recorder.starts.isEmpty)
        trial.cancel()
    }

    func testContinuousEnvelopeHasImmediateOnsetAndNoSilentGap() {
        XCTAssertEqual(PressFeedbackEnvelope.intensity(at: 0), 0.60, accuracy: 0.001)
        for index in 0..<79 {
            XCTAssertGreaterThan(PressFeedbackEnvelope.intensity(at: Double(index) / 100), 0)
        }
        XCTAssertEqual(PressFeedbackEnvelope.intensity(at: 0.8), 0, accuracy: 0.001)
        XCTAssertEqual(PressFeedbackEnvelope.intensity(at: 1), 0)
    }

    func testCancelAndRepressUsesRealControllerAndRejectsPreviousReadyCallback() async {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = make(recorder, feedback)
        for index in 0..<5 {
            trial.begin()
            await wait { recorder.starts.count == index + 1 }
            XCTAssertEqual(trial.phase, .preparing)
            trial.move(y: -100)
            trial.release()
            XCTAssertEqual(trial.phase, .idle)
        }
        trial.begin()
        await wait { recorder.starts.count == 6 }
        for index in 0..<5 { recorder.ready(index) }
        XCTAssertEqual(trial.phase, .preparing)
        XCTAssertEqual(feedback.fades, 0)
        recorder.ready(5)
        await wait { trial.phase == .recording }
        XCTAssertEqual(feedback.begins, 6)
        XCTAssertEqual(feedback.fades, 1)
        trial.cancel()
    }

    func testReleaseBeforeHoldNeverStartsMicrophone() async {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = VoicePressInteraction(recorder: recorder, feedback: feedback, holdDelay: .seconds(1))
        trial.begin()
        trial.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(recorder.starts.isEmpty)
        XCTAssertEqual(trial.phase, .idle)
        XCTAssertEqual(feedback.begins, 1)
        XCTAssertEqual(feedback.fades, 0)
    }

    func testNormalReleaseOnlyFadesExistingFeedbackAndDisplaysText() async {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = make(recorder, feedback)
        trial.begin()
        await wait { recorder.starts.count == 1 }
        recorder.ready(0)
        await wait { trial.phase == .recording }
        trial.release()
        await wait { recorder.finishes.count == 1 }
        recorder.finish(0, text: "买一盒鸡蛋")
        await wait { trial.phase == .idle }
        XCTAssertEqual(trial.message, "买一盒鸡蛋")
        XCTAssertEqual(feedback.begins, 1)
        XCTAssertEqual(feedback.fades, 1)
        XCTAssertEqual(feedback.boundaries, 0)
    }

    func testCancelAfterReadyAllowsAnotherRecording() async {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = make(recorder, feedback)
        for index in 0..<5 {
            trial.begin()
            await wait { recorder.starts.count == index + 1 }
            recorder.ready(index)
            await wait { trial.phase == .recording }
            trial.move(y: -100)
            trial.release()
            XCTAssertEqual(trial.phase, .idle)
        }
        XCTAssertEqual(feedback.fades, 5)
        XCTAssertTrue(recorder.finishes.isEmpty)
    }

    func testBoundaryHysteresisDoesNotRepeatFeedbackWhileStationary() {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = make(recorder, feedback)
        trial.begin()
        for y in [-100, -100, -80, -70] { trial.move(y: CGFloat(y)) }
        XCTAssertTrue(trial.cancelling)
        XCTAssertEqual(feedback.boundaries, 1)
        trial.move(y: -50)
        XCTAssertFalse(trial.cancelling)
        XCTAssertEqual(feedback.boundaries, 2)
        trial.cancel()
    }

    func testPreparationTimeoutUnlocksAndRejectsLateReady() async {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = VoicePressInteraction(recorder: recorder, feedback: feedback, holdDelay: .zero,
                                    prepareLimit: .milliseconds(30))
        trial.begin()
        await wait { recorder.starts.count == 1 }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(trial.phase, .idle)
        XCTAssertTrue(trial.message.contains("准备时间太长"))
        recorder.ready(0)
        XCTAssertEqual(feedback.fades, 0)
        trial.begin()
        XCTAssertEqual(trial.phase, .preparing)
        trial.cancel()
    }

    func testFinishTimeoutPreservesTextAndCannotOverwriteNextPress() async {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = VoicePressInteraction(recorder: recorder, feedback: feedback, holdDelay: .zero,
                                    finishLimit: .milliseconds(30))
        trial.begin()
        await wait { recorder.starts.count == 1 }
        recorder.ready(0)
        await wait { trial.phase == .recording }
        recorder.text = "未整理完的话"
        trial.release()
        await wait { recorder.finishes.count == 1 }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(trial.phase, .idle)
        XCTAssertTrue(trial.message.contains("未整理完的话"))
        trial.begin()
        await wait { recorder.starts.count == 2 }
        recorder.finish(0, text: "过期结果")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(trial.phase, .preparing)
        XCTAssertFalse(trial.message.contains("过期结果"))
        trial.cancel()
        recorder.ready(1)
    }

    func testInterruptionDuringPreparationThenRetry() async {
        let recorder = Recorder()
        let feedback = Feedback()
        let trial = make(recorder, feedback)
        trial.begin()
        await wait { recorder.starts.count == 1 }
        trial.cancel() // Same path as scene inactivity or leaving the trial.
        trial.begin()
        await wait { recorder.starts.count == 2 }
        recorder.ready(0)
        recorder.ready(1)
        await wait { trial.phase == .recording }
        XCTAssertEqual(feedback.fades, 1)
        trial.cancel()
    }

    private func make(_ recorder: Recorder, _ feedback: Feedback) -> VoicePressInteraction {
        VoicePressInteraction(recorder: recorder, feedback: feedback, holdDelay: .zero)
    }
    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Controller did not reach expected state", file: file, line: line)
    }

    private final class Recorder: VoicePressRecording {
        var text = ""
        var error: String?
        var finalizationTimeout: Duration = .seconds(3)
        var starts: [(ready: () -> Void, completion: CheckedContinuation<Bool, Never>)] = []
        var finishes: [CheckedContinuation<String, Never>] = []
        func start(ready: @escaping () -> Void) async -> Bool {
            await withCheckedContinuation { starts.append((ready, $0)) }
        }
        func ready(_ index: Int) {
            starts[index].ready()
            starts[index].completion.resume(returning: true)
        }
        func stop() async -> String { await withCheckedContinuation { finishes.append($0) } }
        func finish(_ index: Int, text: String) { finishes[index].resume(returning: text) }
        func cancel() {}
        nonisolated deinit {}
    }
    private final class Feedback: VoicePressFeedback {
        var begins = 0
        var fades = 0
        var boundaries = 0
        func begin() { begins += 1 }
        func fade() { fades += 1 }
        func stop() {}
        func boundary() { boundaries += 1 }
        nonisolated deinit {}
    }
}
