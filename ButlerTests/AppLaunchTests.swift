import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class AppLaunchTests: XCTestCase {
    private struct OpenFailure: Error, CustomStringConvertible {
        var description: String { "store damaged" }
    }

    func testFailedOpenReportsInsteadOfCrashingAndRetrySucceeds() throws {
        var attempts = 0
        var fails = true
        let launch = AppLaunch(makeContainer: {
            attempts += 1
            if fails { throw OpenFailure() }
            return try ButlerStore.makePreviewContainer()
        }, configuresServices: false)

        XCTAssertNil(launch.container)
        XCTAssertEqual(launch.failure, "store damaged")
        XCTAssertEqual(attempts, 1)

        launch.open()
        XCTAssertNil(launch.container, "Still failing: retry must not invent an empty store")
        XCTAssertEqual(attempts, 2)

        fails = false
        launch.open()
        XCTAssertNotNil(launch.container)
        XCTAssertNil(launch.failure)
        XCTAssertEqual(attempts, 3)
    }

    func testOpenedStoreIsNeverReplaced() throws {
        var attempts = 0
        let launch = AppLaunch(makeContainer: {
            attempts += 1
            return try ButlerStore.makePreviewContainer()
        }, configuresServices: false)
        let first = try XCTUnwrap(launch.container)

        launch.open()
        XCTAssertTrue(launch.container === first)
        XCTAssertEqual(attempts, 1)
    }
}
