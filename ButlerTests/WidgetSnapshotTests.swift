import Foundation
import XCTest
@testable import Butler

final class WidgetSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func rows(_ count: Int) -> [WidgetSnapshot.Row] {
        (0..<count).map { .init(id: UUID(), title: "记录\($0)", detail: "日期\($0)") }
    }

    func testCountsAreNotTruncatedToDisplayRowsAndKeepExactIDs() {
        let tasks = rows(9), items = rows(5)
        let snapshot = WidgetSnapshot(now: date("2026-09-30T14:00:00Z"), calendar: calendar, tasks: tasks, items: items)
        XCTAssertEqual(snapshot.taskCount, 9)
        XCTAssertEqual(snapshot.itemCount, 5)
        XCTAssertEqual(snapshot.tasks, Array(tasks[0...2]))
        XCTAssertEqual(snapshot.items, Array(items[0...2]))
    }

    func testFreshnessRejectsDeadlineFutureClockAndDifferentTimeZone() {
        let now = date("2026-09-30T14:00:00Z")
        let snapshot = WidgetSnapshot(now: now, calendar: calendar, tasks: rows(1), items: [])
        XCTAssertTrue(snapshot.isCurrent(at: now, timeZone: calendar.timeZone))
        XCTAssertTrue(snapshot.isCurrent(at: now.addingTimeInterval(3599), timeZone: calendar.timeZone))
        XCTAssertFalse(snapshot.isCurrent(at: now.addingTimeInterval(3600), timeZone: calendar.timeZone))
        XCTAssertFalse(snapshot.isCurrent(at: now.addingTimeInterval(-1), timeZone: calendar.timeZone))
        XCTAssertFalse(snapshot.isCurrent(at: now, timeZone: TimeZone(identifier: "Asia/Shanghai")!))
        let automatic = WidgetSnapshot(now: now, calendar: calendar, tasks: rows(1), items: [], nextChange: now.addingTimeInterval(47))
        XCTAssertTrue(automatic.isCurrent(at: now.addingTimeInterval(46), timeZone: calendar.timeZone))
        XCTAssertFalse(automatic.isCurrent(at: now.addingTimeInterval(47), timeZone: calendar.timeZone))
    }

    func testLocalMidnightOnDaylightSavingDayIsNotTwentyFourHoursAfterDayStart() {
        // New York's fall-back day is 25 hours. 23:45 local is 04:45Z the next UTC day.
        let now = date("2026-11-02T04:45:00Z")
        let snapshot = WidgetSnapshot(now: now, calendar: calendar, tasks: [], items: [])
        XCTAssertEqual(snapshot.validUntil, date("2026-11-02T05:00:00Z"))
        XCTAssertTrue(snapshot.isCurrent(at: date("2026-11-02T04:59:59Z"), timeZone: calendar.timeZone))
        XCTAssertFalse(snapshot.isCurrent(at: date("2026-11-02T05:00:00Z"), timeZone: calendar.timeZone))
    }

    func testUnavailableIsNotEmptyAndDiscardsTitles() {
        let now = date("2026-09-30T14:00:00Z")
        let empty = WidgetSnapshot(now: now, calendar: calendar, tasks: [], items: [])
        let unavailable = WidgetSnapshot(now: now, calendar: calendar, tasks: rows(2), items: rows(1), available: false)
        XCTAssertTrue(empty.isCurrent(at: now, timeZone: calendar.timeZone))
        XCTAssertFalse(unavailable.isCurrent(at: now, timeZone: calendar.timeZone))
        XCTAssertTrue(unavailable.tasks.isEmpty)
        XCTAssertTrue(unavailable.items.isEmpty)
    }

    func testAtomicReplacementRemovesOldRowsAndMissingOrCorruptFileThrows() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        XCTAssertThrowsError(try WidgetSnapshot.read(from: file))
        let first = WidgetSnapshot(now: .now, calendar: calendar, tasks: rows(2), items: rows(1))
        try first.write(to: file)
        XCTAssertEqual(try WidgetSnapshot.read(from: file), first)
        let replacement = WidgetSnapshot(now: .now, calendar: calendar, tasks: [], items: [])
        try replacement.write(to: file)
        XCTAssertEqual(try WidgetSnapshot.read(from: file), replacement)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try WidgetSnapshot.read(from: file))
        XCTAssertThrowsError(try replacement.write(to: directory.appendingPathComponent("missing/child.json")))
    }

    func testLinksRoundTripIdentityAndNeverAcceptCommandsOrAmbiguousPaths() {
        let task = UUID(), lot = UUID()
        for destination in [WidgetDestination.overview, .task(task), .lot(lot)] {
            XCTAssertEqual(WidgetDestination(url: destination.url), destination)
        }
        for raw in ["https://widget/task/\(task)", "butler://other/task/\(task)", "butler://widget/complete/\(task)",
                    "butler://widget/task/\(task)?confirm=true", "butler://widget/task/\(task)#complete",
                    "butler://widget/task/not-a-uuid", "butler://widget/task/\(task)/", "butler://widget//task/\(task)",
                    "butler://user@widget/overview", "butler://widget:42/overview"] {
            XCTAssertNil(WidgetDestination(url: URL(string: raw)!), raw)
        }
    }

    @MainActor func testWidgetRouteWaitsWithoutReplacingUnconsumedShortcut() async throws {
        let navigation = ShortcutNavigation(), id = UUID()
        try navigation.openWidgetURL(WidgetDestination.lot(id).url)
        XCTAssertEqual(navigation.request?.destination, .lot(id))
        XCTAssertThrowsError(try navigation.openWidgetURL(WidgetDestination.overview.url))
        XCTAssertEqual(navigation.request?.destination, .lot(id))
        navigation.consume(try XCTUnwrap(navigation.request?.id))
        try navigation.openWidgetURL(URL(string: "butler://widget/delete/\(id)")!)
        XCTAssertNil(navigation.request)
        try navigation.openWidgetURL(WidgetDestination.overview.url)
        XCTAssertEqual(navigation.request?.destination, .general)
    }
}
