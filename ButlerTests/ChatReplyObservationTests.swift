import Foundation
import Observation
import XCTest
@testable import Butler

final class ChatReplyObservationTests: XCTestCase {
    @MainActor func testTextUpdatesDoNotInvalidateRequestIdentityReaders() async {
        let owner = ProgressOwner()
        owner.progress.begin(UUID())
        let parent = ChangeCounter(), bubble = ChangeCounter()
        var text = ""
        // Re-arm after each update, as a consumer that reads again would do.
        // These are Observation notifications, NOT measured SwiftUI body calls.
        for _ in 0..<1000 {
            withObservationTracking { _ = owner.progress.turnID } onChange: { parent.increment() }
            withObservationTracking { _ = owner.progress.text } onChange: { bubble.increment() }
            text += "家🥛"
            owner.progress.receive(text)
        }
        print("reply observation: updates=1000 identity=\(parent.value) text=\(bubble.value)")
        XCTAssertEqual(parent.value, 0)
        XCTAssertEqual(bubble.value, 1000, "Isolation must not suppress actual text updates")
        XCTAssertEqual(owner.progress.text, text)
    }

    @MainActor func testIdenticalTextDoesNotNotifyButRetryLabelAndFinishStillDo() async {
        let owner = ProgressOwner()
        owner.progress.begin(UUID())
        owner.progress.receive("原文")
        let text = ChangeCounter(), label = ChangeCounter(), identity = ChangeCounter()
        withObservationTracking { _ = owner.progress.text } onChange: { text.increment() }
        withObservationTracking { _ = owner.progress.isPreviousPass } onChange: { label.increment() }
        withObservationTracking { _ = owner.progress.turnID } onChange: { identity.increment() }
        owner.progress.receive("原文")
        XCTAssertEqual(text.value, 0)
        XCTAssertEqual(label.value, 0)
        owner.progress.prepareNextPass()
        XCTAssertEqual(label.value, 1)
        XCTAssertEqual(text.value, 0)
        XCTAssertEqual(identity.value, 0)
        let replacement = ChangeCounter()
        withObservationTracking { _ = owner.progress.isPreviousPass } onChange: { replacement.increment() }
        owner.progress.receive("原文")
        XCTAssertEqual(replacement.value, 1, "Same words in a new pass are no longer previous-pass text")
        owner.progress.finish()
        XCTAssertEqual(text.value, 1)
        XCTAssertEqual(identity.value, 1)
        XCTAssertEqual(owner.progress.text, "")
        XCTAssertNil(owner.progress.turnID)
    }

    @MainActor func testFinishedAnswerAndOtherConversationRemainIndependent() async {
        let owner = ProgressOwner(), other = ProgressOwner()
        let old = ChatTurn(question: "旧问题", answer: "旧答案", replyState: .completed)
        owner.progress.begin(UUID())
        other.progress.begin(UUID())
        other.progress.receive("另一会话的草稿回复")
        let history = ChangeCounter(), unrelated = ChangeCounter()
        withObservationTracking { _ = old.displayedReply(using: owner.progress) } onChange: { history.increment() }
        withObservationTracking { _ = other.progress.text } onChange: { unrelated.increment() }
        owner.progress.receive("新的部分回复")
        owner.progress.prepareNextPass()
        owner.progress.finish()
        XCTAssertEqual(history.value, 0)
        XCTAssertEqual(unrelated.value, 0)
        XCTAssertEqual(old.displayedReply(using: owner.progress), "旧答案")
        XCTAssertEqual(other.progress.text, "另一会话的草稿回复")
        XCTAssertNotNil(other.progress.turnID)
    }
}

@MainActor @Observable
private final class ProgressOwner {
    var progress = ChatReplyProgress()
    nonisolated deinit {}
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
