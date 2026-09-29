import XCTest
import UIKit
@testable import Butler

@MainActor
final class HomeDayInteractionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private var today: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)) }

    func testBothSwipeDirectionsCancelRowTapIncludingTheRelease() {
        for dx: CGFloat in [-120, 120] {
            let interaction = HomeDayInteraction()
            interaction.touchBegan()
            XCTAssertTrue(interaction.allowsTap)
            interaction.touchMoved(CGPoint(x: dx, y: 2))
            interaction.begin(day: today)
            interaction.move(dx)
            XCTAssertFalse(interaction.allowsTap)
            let selected = interaction.finish(translation: dx, velocity: 0, calendar: calendar)
            XCTAssertEqual(selected, calendar.date(byAdding: .day, value: dx < 0 ? 1 : -1, to: today))
            XCTAssertEqual(interaction.offset, 0)
            XCTAssertFalse(interaction.allowsTap, "A Button callback delivered after pan end must still be blocked")
            XCTAssertNil(interaction.finish(translation: -dx, velocity: 0), "A release cannot turn a second page")
        }
    }

    func testAnIntentionalTapAfterSwipingWorksWithoutATimeout() {
        let interaction = HomeDayInteraction()
        interaction.touchBegan()
        interaction.begin(day: today)
        _ = interaction.finish(translation: -100, velocity: -600)
        XCTAssertFalse(interaction.allowsTap)
        interaction.touchBegan()
        interaction.touchMoved(CGPoint(x: 2, y: 3))
        XCTAssertTrue(interaction.allowsTap, "The next real touch can open a row immediately")
    }

    func testShortDragCancelsTapWithoutTurningADay() {
        let interaction = HomeDayInteraction()
        interaction.touchBegan()
        interaction.touchMoved(CGPoint(x: -18, y: 2))
        interaction.begin(day: today)
        XCTAssertNil(interaction.finish(translation: -18, velocity: -800))
        XCTAssertFalse(interaction.allowsTap, "An incomplete swipe is not a click")
    }

    func testNavigationCancellationCannotChangeTheDateOnReturn() {
        let interaction = HomeDayInteraction()
        interaction.touchBegan()
        interaction.begin(day: today)
        interaction.move(-100)
        interaction.cancel()
        XCTAssertNil(interaction.finish(translation: 180, velocity: 900), "A cancelled gesture must not reuse its old starting day")
        XCTAssertEqual(interaction.offset, 0)
        interaction.touchBegan()
        XCTAssertTrue(interaction.allowsTap)
    }

    func testDirectionLockLeavesVerticalAndDiagonalMotionToScrolling() {
        XCTAssertTrue(HomeDayInteraction.isHorizontal(CGPoint(x: -300, y: 20)))
        XCTAssertTrue(HomeDayInteraction.isHorizontal(CGPoint(x: 300, y: -20)))
        XCTAssertFalse(HomeDayInteraction.isHorizontal(CGPoint(x: 20, y: -300)))
        XCTAssertFalse(HomeDayInteraction.isHorizontal(CGPoint(x: 100, y: 100)))
        XCTAssertFalse(HomeDayInteraction.isHorizontal(.zero))
        let interaction = HomeDayInteraction()
        interaction.touchBegan()
        interaction.touchMoved(CGPoint(x: 2, y: 80))
        XCTAssertFalse(interaction.allowsTap)
        XCTAssertNil(interaction.finish(translation: 2, velocity: 20))
    }

    func testScrollPanWaitsForDirectionButNavigationBackGestureDoesNot() {
        let coordinator = HomeDaySwipe.Coordinator()
        let browse = HomeDaySwipe.DayPanRecognizer()
        let scroll = UIScrollView()
        XCTAssertTrue(coordinator.gestureRecognizer(browse, shouldBeRequiredToFailBy: scroll.panGestureRecognizer))
        XCTAssertFalse(coordinator.gestureRecognizer(browse, shouldBeRequiredToFailBy: UIScreenEdgePanGestureRecognizer()))
        XCTAssertFalse(coordinator.gestureRecognizer(browse, shouldBeRequiredToFailBy: UITapGestureRecognizer()))
    }
}
