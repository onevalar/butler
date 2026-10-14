import Foundation
import Observation
import XCTest
@testable import Butler

final class ChatScrollPolicyTests: XCTestCase {
    private func geometry(offset: CGFloat = 600, content: CGFloat = 1_200,
                          viewport: CGFloat = 600, width: CGFloat = 390,
                          top: CGFloat = 0, bottom: CGFloat = 0) -> ChatScrollPolicy.Geometry {
        .init(offset: offset, contentHeight: content, containerHeight: viewport,
              containerWidth: width, topInset: top, bottomInset: bottom)
    }

    @MainActor private func atBottom() -> ChatScrollPolicy {
        let policy = ChatScrollPolicy()
        policy.appear()
        policy.geometryChanged(to: geometry())
        XCTAssertEqual(policy.takeScroll(), .immediate)
        return policy
    }

    @MainActor private func readingOlder() -> ChatScrollPolicy {
        let policy = atBottom()
        policy.phaseChanged(to: .tracking)
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 200))
        policy.phaseChanged(to: .idle)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
        return policy
    }

    @MainActor func testVisibleFooterHidesJumpDespiteLazyHeightEstimate() async {
        let policy = readingOlder()
        policy.bottomVisibilityChanged(true)
        XCTAssertFalse(policy.showsReturnToLatest)
        policy.geometryChanged(to: geometry(offset: 200, content: 1600))
        XCTAssertFalse(policy.showsReturnToLatest)
        policy.bottomVisibilityChanged(false)
        XCTAssertTrue(policy.showsReturnToLatest)
    }

    @MainActor func testScrollSamplesDoNotInvalidateUnchangedPresentation() async {
        let policy = readingOlder()
        policy.phaseChanged(to: .interacting)
        let invalidated = expectation(description: "No per-pixel presentation updates")
        invalidated.isInverted = true
        withObservationTracking {
            _ = policy.followingBottom
            _ = policy.showsReturnToLatest
            _ = policy.revision
        } onChange: { invalidated.fulfill() }
        for offset in 210...300 { policy.geometryChanged(to: geometry(offset: CGFloat(offset))) }
        await fulfillment(of: [invalidated], timeout: 0.1)
    }

    @MainActor func testLatestButtonUsesActualDistanceAfterLayoutChanges() async {
        let policy = readingOlder()
        XCTAssertTrue(policy.showsReturnToLatest)
        policy.geometryChanged(to: geometry(offset: 600))
        XCTAssertFalse(policy.showsReturnToLatest)
        XCTAssertFalse(policy.followingBottom, "Do not change reading intent just because content resized")
        policy.geometryChanged(to: geometry(offset: 0, content: 200, viewport: 600))
        XCTAssertFalse(policy.showsReturnToLatest, "Short content has no hidden latest message")
        policy.geometryChanged(to: geometry(offset: 0, content: 1200, viewport: 600))
        XCTAssertTrue(policy.showsReturnToLatest)
    }

    @MainActor func testInitialShortContentFollowsWhenItBecomesScrollable() async {
        let policy = ChatScrollPolicy()
        policy.appear()
        policy.geometryChanged(to: geometry(offset: -44, content: 150, top: 44, bottom: 80))
        XCTAssertEqual(policy.takeScroll(), .immediate)
        XCTAssertTrue(policy.followingBottom)
        policy.geometryChanged(to: geometry(offset: -44, content: 900, top: 44, bottom: 80))
        XCTAssertEqual(policy.takeScroll(), .immediate)
        XCTAssertTrue(policy.followingBottom)
    }

    @MainActor func testGrowthAndRelatedUpdatesCoalesceWithoutChangingIntent() async {
        let policy = atBottom()
        policy.geometryChanged(to: geometry(content: 1_250))
        policy.geometryChanged(to: geometry(content: 1_400))
        policy.geometryChanged(to: geometry(content: 1_500))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .immediate)
        XCTAssertNil(policy.takeScroll())
    }

    @MainActor func testReadingOlderSurvivesContentKeyboardAndRotationChanges() async {
        let policy = readingOlder()
        policy.geometryChanged(to: geometry(offset: 200, content: 1_600))
        policy.geometryChanged(to: geometry(offset: 200, content: 1_600, viewport: 300))
        policy.geometryChanged(to: geometry(offset: 250, content: 1_800, viewport: 500, width: 844))
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    @MainActor func testAutomaticOffsetChangesAndAnimationAreNotUserIntent() async {
        let policy = atBottom()
        policy.geometryChanged(to: geometry(offset: 200))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
        policy.phaseChanged(to: .animating)
        policy.geometryChanged(to: geometry(offset: 400))
        policy.phaseChanged(to: .idle)
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll(), "Animation completion must not create a scroll loop")
    }

    @MainActor func testAutomaticArrivalAtBottomDoesNotResumeReadingUser() async {
        let policy = readingOlder()
        policy.geometryChanged(to: geometry(offset: 600))
        policy.geometryChanged(to: geometry(offset: 600, content: 1_500))
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    @MainActor func testUserReturnToBottomResumesFollowingIncludingDeceleration() async {
        let policy = readingOlder()
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 500))
        policy.phaseChanged(to: .decelerating)
        policy.geometryChanged(to: geometry(offset: 590))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll(), "Never fight native momentum")
        policy.phaseChanged(to: .idle)
        XCTAssertEqual(policy.takeScroll(), .immediate)
        policy.geometryChanged(to: geometry(offset: 600, content: 1_500))
        XCTAssertEqual(policy.takeScroll(), .immediate)
    }

    @MainActor func testTouchCancelsQueuedFollowAndDragAwayWins() async {
        let policy = atBottom()
        policy.geometryChanged(to: geometry(content: 1_500))
        let queuedRevision = policy.revision
        policy.phaseChanged(to: .tracking)
        XCTAssertGreaterThan(policy.revision, queuedRevision)
        XCTAssertNil(policy.pending)
        XCTAssertTrue(policy.followingBottom, "Touching without dragging is not an intent change")
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 200, content: 1_500))
        policy.phaseChanged(to: .idle)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    @MainActor func testDragPausesEvenWhenStreamingOrKeyboardChangesInTheSameFrame() async {
        var policy = atBottom()
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 550, content: 1_600, viewport: 400))
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
        policy.phaseChanged(to: .idle)
        XCTAssertNil(policy.takeScroll(), "Ambiguous simultaneous layout must not pull the reader back down")

        policy = readingOlder()
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 700, content: 1_300))
        policy.phaseChanged(to: .idle)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    @MainActor func testKeyboardResizeDoesNotRaceNativeSizeAnchoring() async {
        let policy = atBottom()
        policy.geometryChanged(to: geometry(content: 1600, viewport: 320, bottom: 40))
        XCTAssertNil(policy.takeScroll())
        policy.geometryChanged(to: geometry(offset: 1320, content: 1600, viewport: 320, bottom: 40))
        XCTAssertNil(policy.takeScroll())
        XCTAssertTrue(policy.followingBottom)
        XCTAssertFalse(policy.showsReturnToLatest)
    }

    @MainActor func testRapidKeyboardAndComposerLayoutUsesOneImmediateCorrection() async {
        let policy = atBottom()
        policy.geometryChanged(to: geometry(content: 1_400))
        policy.geometryChanged(to: geometry(content: 1_400, viewport: 300, bottom: 60))
        policy.geometryChanged(to: geometry(content: 1_400, viewport: 580, bottom: 20))
        policy.geometryChanged(to: geometry(content: 1_400, viewport: 300, bottom: 60))
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .immediate)
        XCTAssertNil(policy.takeScroll())
    }

    @MainActor func testSendExplicitlyResumesFollowingBeforeAndAfterLayout() async {
        let policy = readingOlder()
        policy.sendToLatest()
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .animated)
        policy.geometryChanged(to: geometry(offset: 200, content: 1_500))
        XCTAssertEqual(policy.takeScroll(), .immediate)
    }

    @MainActor func testDisappearInvalidatesWorkAndReappearanceStartsAtBottom() async {
        let policy = atBottom()
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

    @MainActor func testBottomDistanceAccountsForInsetsAndOverscroll() async {
        XCTAssertEqual(geometry(offset: 680, top: 44, bottom: 80).distanceFromBottom, 0)
        XCTAssertEqual(geometry(offset: 600, top: 44, bottom: 80).distanceFromBottom, 80)
        XCTAssertEqual(geometry(offset: 700, top: 44, bottom: 80).distanceFromBottom, 0)
        XCTAssertEqual(geometry(offset: -44, content: 150, top: 44, bottom: 80).distanceFromBottom, 0)
    }

    @MainActor func testReadingAnchorSurvivesReopenAndHiddenCallbacksCannotReplaceIt() async {
        let original = UUID(), unrelated = UUID()
        let policy = readingOlder()
        policy.positionChanged(to: original)
        policy.positionChanged(to: nil)
        XCTAssertEqual(policy.visibleTurnID, original)
        policy.disappear()
        XCTAssertFalse(policy.showsReturnToLatest)
        policy.positionChanged(to: unrelated)
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 900, content: 1_500))
        policy.appear(validTurnIDs: [original, unrelated])
        XCTAssertEqual(policy.visibleTurnID, original)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertFalse(policy.showsReturnToLatest, "Wait for measured viewport after reopening")
        policy.geometryChanged(to: geometry(offset: 180, content: 2_400, viewport: 300, bottom: 90))
        XCTAssertNil(policy.takeScroll(), "Restoring history must not enqueue a competing bottom scroll")
    }

    @MainActor func testLatestModeDoesNotRestoreOldVisibleMessageAfterReopen() async {
        let visible = UUID()
        let policy = atBottom()
        policy.positionChanged(to: visible)
        policy.disappear()
        XCTAssertNil(policy.visibleTurnID)
        policy.appear(validTurnIDs: [visible, UUID()])
        XCTAssertTrue(policy.followingBottom)
        XCTAssertFalse(policy.showsReturnToLatest)
        XCTAssertEqual(policy.takeScroll(), .immediate)
    }

    @MainActor func testHistoryReplacementResetsOnlyMissingAnchorIncludingWhenHidden() async {
        let anchor = UUID(), other = UUID()
        let policy = readingOlder()
        policy.positionChanged(to: anchor)
        policy.reconcileHistory([other, anchor])
        XCTAssertEqual(policy.visibleTurnID, anchor)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
        policy.disappear()
        policy.reconcileHistory([other])
        XCTAssertNil(policy.visibleTurnID)
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
        policy.appear(validTurnIDs: [other])
        XCTAssertEqual(policy.takeScroll(), .immediate)
    }

    @MainActor func testMissingBookmarkOnAppearAndClearedHistoryFallBackToLatest() async {
        var policy = readingOlder()
        policy.positionChanged(to: UUID())
        policy.disappear()
        policy.appear(validTurnIDs: [UUID()])
        XCTAssertNil(policy.visibleTurnID)
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .immediate)
        policy = readingOlder()
        policy.positionChanged(to: UUID())
        policy.reconcileHistory([])
        XCTAssertNil(policy.visibleTurnID)
        XCTAssertTrue(policy.followingBottom)
        XCTAssertEqual(policy.takeScroll(), .immediate)
    }

    @MainActor func testReturnToLatestClearsBookmarkAndQueuesOnlyOneJump() async {
        let policy = readingOlder()
        policy.positionChanged(to: UUID())
        XCTAssertTrue(policy.showsReturnToLatest)
        policy.sendToLatest()
        XCTAssertNil(policy.visibleTurnID)
        XCTAssertFalse(policy.showsReturnToLatest)
        XCTAssertEqual(policy.takeScroll(), .animated)
        XCTAssertNil(policy.takeScroll())
        policy.geometryChanged(to: geometry(offset: 200, content: 1_800, viewport: 280))
        XCTAssertNil(policy.takeScroll(), "Native anchoring owns keyboard resizing; do not queue another jump")
    }

    @MainActor func testExplicitJumpOverridesOldMomentumButNewTouchStillCancelsIt() async {
        let policy = readingOlder()
        policy.phaseChanged(to: .decelerating)
        policy.sendToLatest()
        XCTAssertEqual(policy.takeScroll(), .animated, "The latest button must work while the old scroll coasts")
        policy.sendToLatest()
        policy.phaseChanged(to: .tracking)
        XCTAssertNil(policy.takeScroll())
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 150))
        policy.phaseChanged(to: .idle)
        XCTAssertFalse(policy.followingBottom)
        XCTAssertNil(policy.takeScroll())
    }

    @MainActor func testUserReturnThresholdDistinguishes24From25Points() async {
        let policy = readingOlder()
        policy.phaseChanged(to: .interacting)
        policy.geometryChanged(to: geometry(offset: 575)) // 25 points away.
        XCTAssertFalse(policy.followingBottom)
        policy.geometryChanged(to: geometry(offset: 576)) // 24 points away.
        XCTAssertTrue(policy.followingBottom)
        XCTAssertNil(policy.takeScroll(), "Do not fight an active drag")
        policy.phaseChanged(to: .idle)
        XCTAssertEqual(policy.takeScroll(), .immediate)
    }
}
