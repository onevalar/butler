import Foundation
import XCTest
@testable import Butler

@MainActor final class ShortcutNavigationTests: XCTestCase {
    func testRequestWaitsForSceneAndOnlyMatchingConsumptionClearsIt() async throws {
        let navigation = ShortcutNavigation(), taskID = UUID()
        try navigation.open(.task(taskID))
        let request = try XCTUnwrap(navigation.request)
        XCTAssertEqual(request.destination, .task(taskID))
        navigation.consume(UUID())
        XCTAssertEqual(navigation.request, request)
        navigation.consume(request.id)
        XCTAssertNil(navigation.request)
        navigation.consume(request.id)
        XCTAssertNil(navigation.request)
    }
    func testSecondInvocationCannotOverwritePendingInput() async throws {
        let navigation = ShortcutNavigation()
        try navigation.open(.inventory("牛奶两瓶"))
        XCTAssertThrowsError(try navigation.open(.inventory("鸡蛋三个")))
        XCTAssertEqual(navigation.request?.destination, .inventory("牛奶两瓶"))
        navigation.consume(try XCTUnwrap(navigation.request?.id))
        try navigation.open(.inventory("鸡蛋三个"))
        XCTAssertEqual(navigation.request?.destination, .inventory("鸡蛋三个"))
    }
    func testEmptyAndOversizedInputNeverQueues() async throws {
        let navigation = ShortcutNavigation()
        XCTAssertThrowsError(try navigation.open(.inventory(" \n ")))
        XCTAssertThrowsError(try navigation.open(.inventory(String(repeating: "物", count: 10_001))))
        XCTAssertNil(navigation.request)
        try navigation.open(.inventory(String(repeating: "物", count: 10_000)))
        XCTAssertNotNil(navigation.request)
    }
    func testScreenshotRequestPreservesModeAndCannotReplacePendingCapture() throws {
        let navigation = ShortcutNavigation(), id = UUID()
        try navigation.open(.screenshot(id, .voice))
        XCTAssertEqual(navigation.request?.destination, .screenshot(id, .voice))
        XCTAssertThrowsError(try navigation.open(.screenshot(UUID(), .typing)))
        XCTAssertEqual(navigation.request?.destination, .screenshot(id, .voice))
    }

}
