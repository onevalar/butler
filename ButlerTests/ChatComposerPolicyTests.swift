import XCTest
@testable import Butler

final class ChatComposerPolicyTests: XCTestCase {
    private func policy(_ draft: String = "", photos: Int = 0, working: Bool = false,
                        voice: ChatDictationSession.Phase = .idle) -> ChatComposerPolicy {
        .init(draft: draft, photoCount: photos, working: working, voicePhase: voice)
    }

    func testWhitespaceIsEmptyButPhotoOnlyMessageCanBeSent() {
        XCTAssertEqual(policy(" \n ").action, .voice)
        XCTAssertFalse(policy(" \n ").showsInlineMicrophone)
        XCTAssertEqual(policy(" \n ", photos: 1).action, .send)
        XCTAssertTrue(policy(" \n ", photos: 1).showsInlineMicrophone)
    }

    func testDraftRetainsSendModeEvenWhenItIsTooLongToSend() {
        let state = policy(String(repeating: "字", count: 8_001))
        XCTAssertEqual(state.action, .send)
        XCTAssertTrue(state.showsInlineMicrophone)
        XCTAssertTrue(state.canStartVoice)
    }

    func testResponseCanBeStoppedWhileNextDraftRemainsEditable() {
        let state = policy("下一条", working: true)
        XCTAssertEqual(state.action, .stopResponse)
        XCTAssertTrue(state.canEditText)
        XCTAssertTrue(state.showsInlineMicrophone)
        XCTAssertFalse(state.canStartVoice)
    }

    func testRecognitionOwnsDraftUntilFinalizationCompletes() {
        for (phase, action) in [
            (ChatDictationSession.Phase.preparing, ChatComposerPolicy.Action.cancelPreparation),
            (.listening, .stopDictation), (.finishing, .finishDictation)
        ] {
            let state = policy("已有文字", voice: phase)
            XCTAssertEqual(state.action, action)
            XCTAssertFalse(state.canEditText)
            XCTAssertFalse(state.canStartVoice)
            XCTAssertFalse(state.showsInlineMicrophone)
        }
    }

    func testRapidStartAndStopCannotCreateAnotherSession() throws {
        var session = ChatDictationSession()
        let id = try XCTUnwrap(session.begin())
        XCTAssertNil(session.begin())
        XCTAssertNil(session.finish(), "Preparing is cancellable, not a recording that can be finalized")
        XCTAssertTrue(session.prepared(id, listening: true))
        XCTAssertEqual(session.finish(), id)
        XCTAssertNil(session.finish())
        XCTAssertNil(session.begin())
        XCTAssertTrue(session.end(id))
        XCTAssertTrue(policy("已有文字", voice: session.phase).canEditText)
        XCTAssertEqual(policy("已有文字", voice: session.phase).action, .send)
    }

    func testLateCompletionAfterCloseOrScopeChangeCannotOwnNextDraft() throws {
        var session = ChatDictationSession()
        let old = try XCTUnwrap(session.begin())
        session.prepared(old, listening: true)
        _ = session.finish()
        session.cancel()
        let new = try XCTUnwrap(session.begin())
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(session.accepts(old))
        XCTAssertFalse(session.end(old))
        XCTAssertFalse(session.prepared(old, listening: true))
        XCTAssertEqual(session.id, new)
        XCTAssertTrue(session.prepared(new, listening: true))
    }

    func testDeniedPermissionRestoresManualEditingAndAllowsRetry() throws {
        var session = ChatDictationSession()
        let id = try XCTUnwrap(session.begin())
        XCTAssertTrue(session.prepared(id, listening: false))
        XCTAssertEqual(policy("原草稿", voice: session.phase).action, .send)
        XCTAssertTrue(policy("原草稿", voice: session.phase).canEditText)
        XCTAssertNotNil(session.begin())
    }
}
