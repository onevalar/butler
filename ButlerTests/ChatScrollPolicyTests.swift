import Foundation
import XCTest
@testable import Butler

final class ChatScrollPolicyTests: XCTestCase {
    private func geometry(offset: CGFloat = 600, content: CGFloat = 1_200,
                          viewport: CGFloat = 600, width: CGFloat = 390,
                          top: CGFloat = 0, bottom: CGFloat = 0) -> ChatScrollPolicy.Geometry {
        .init(offset: offset, contentHeight: content, containerHeight: viewport,
              containerWidth: width, topInset: top, bottomInset: bottom)
    }

    private func atBottom() -> ChatScrollPolicy {
        var policy = ChatScrollPolicy()
        policy.appear()
        policy.geometryChanged(to: geometry())
        XCTAssertEqual(policy.takeScroll(), .immediate)
        return policy
    }

    private func readingOlder() -> ChatScrollPolicy {
        var policy = atBottom()
        policy.phaseChanged(to: .tracking)
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 200))
        policy.phaseChanged(to: .idle)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
        return policy
    }

    func testInitialShortContentFollowsWhenItBecomesScrollable() {
        var policy = ChatScrollPolicy()
        policy.appear()
        policy.geometryChanged(to: geometry(offset: -44, content: 150, top: 44, bottom: 80))
        XCTAssertEqual(policy.takeScroll(), .immediate)
        XCTAssertTrue(policy.followingBottom)
        policy.geometryChanged(to: geometry(offset: -44, content: 900, top: 44, bottom: 80))
        XCTAssertEqual(policy.takeScroll(), .animated)
        XCTAssertTrue(policy.followingBottom)
    }

    func testGrowthAndRelatedUpdatesCoalesceWithoutChangingIntent() {
        var policy = atBottom()
        policy.geometryChanged(to: geometry(content: 1_250))
        policy.geometryChanged(to: geometry(content: 1_400))
        policy.geometryChanged(to: geometry(content: 1_500))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .animated)
        XCTAssertNil(policy.takeScroll())
    }

    func testReadingOlderSurvivesContentKeyboardAndRotationChanges() {
        var policy = readingOlder()
        policy.geometryChanged(to: geometry(offset: 200, content: 1_600))
        policy.geometryChanged(to: geometry(offset: 200, content: 1_600, viewport: 300))
        policy.geometryChanged(to: geometry(offset: 250, content: 1_800, viewport: 500, width: 844))
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    func testAutomaticOffsetChangesAndAnimationAreNotUserIntent() {
        var policy = atBottom()
        policy.geometryChanged(to: geometry(offset: 200))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
        policy.phaseChanged(to: .animating)
        policy.geometryChanged(to: geometry(offset: 400))
        policy.phaseChanged(to: .idle)
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll(), "Animation completion must not create a scroll loop")
    }

    func testAutomaticArrivalAtBottomDoesNotResumeReadingUser() {
        var policy = readingOlder()
        policy.geometryChanged(to: geometry(offset: 600))
        policy.geometryChanged(to: geometry(offset: 600, content: 1_500))
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    func testUserReturnToBottomResumesFollowingIncludingDeceleration() {
        var policy = readingOlder()
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 500))
        policy.phaseChanged(to: .decelerating)
        policy.geometryChanged(to: geometry(offset: 590))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll(), "Never fight native momentum")
        policy.phaseChanged(to: .idle)
        XCTAssertEqual(policy.takeScroll(), .immediate)
        policy.geometryChanged(to: geometry(offset: 600, content: 1_500))
        XCTAssertEqual(policy.takeScroll(), .animated)
    }

    func testTouchCancelsQueuedFollowAndDragAwayWins() {
        var policy = atBottom()
        policy.geometryChanged(to: geometry(content: 1_500))
        let queuedRevision = policy.revision
        policy.phaseChanged(to: .tracking)
        XCTAssertGreaterThan(policy.revision, queuedRevision)
        XCTAssertNil(policy.pending)
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 200, content: 1_500))
        policy.phaseChanged(to: .idle)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    func testLayoutDuringUserPhaseIsNotMistakenForDrag() {
        var policy = atBottom()
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 550, content: 1_600, viewport: 400))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
        policy.phaseChanged(to: .idle)
        XCTAssertEqual(policy.takeScroll(), .immediate)

        policy = readingOlder()
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 700, content: 1_300))
        policy.phaseChanged(to: .idle)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    func testRapidKeyboardAndComposerLayoutUsesOneImmediateCorrection() {
        var policy = atBottom()
        policy.geometryChanged(to: geometry(content: 1_400))
        policy.geometryChanged(to: geometry(content: 1_400, viewport: 300, bottom: 60))
        policy.geometryChanged(to: geometry(content: 1_400, viewport: 580, bottom: 20))
        policy.geometryChanged(to: geometry(content: 1_400, viewport: 300, bottom: 60))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .immediate)
        XCTAssertNil(policy.takeScroll())
    }

    func testSendExplicitlyResumesFollowingBeforeAndAfterLayout() {
        var policy = readingOlder()
        policy.sendToLatest()
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .animated)
        policy.geometryChanged(to: geometry(offset: 200, content: 1_500))
        XCTAssertEqual(policy.takeScroll(), .animated)
    }

    func testDisappearInvalidatesWorkAndReappearanceStartsAtBottom() {
        var policy = atBottom()
        policy.geometryChanged(to: geometry(content: 1_500))
        let queuedRevision = policy.revision
        policy.disappear()
        XCTAssertGreaterThan(policy.revision, queuedRevision)
        policy.geometryChanged(to: geometry(content: 1_600))
        policy.sendToLatest()
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.takeScroll())
        policy.appear()
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .immediate)
    }

    func testBottomDistanceAccountsForInsetsAndOverscroll() {
        XCTAssertEqual(geometry(offset: 680, top: 44, bottom: 80).distanceFromBottom, 0)
        XCTAssertEqual(geometry(offset: 600, top: 44, bottom: 80).distanceFromBottom, 80)
        XCTAssertEqual(geometry(offset: 700, top: 44, bottom: 80).distanceFromBottom, 0)
        XCTAssertEqual(geometry(offset: -44, content: 150, top: 44, bottom: 80).distanceFromBottom, 0)
    }
}
