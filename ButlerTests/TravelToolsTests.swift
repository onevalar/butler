import CoreLocation
import Foundation
import SwiftData
import UserNotifications
import XCTest
@testable import Butler

@MainActor final class TravelToolsTests: XCTestCase {
    func testDialogueRequiresSeparateConfirmationsAndDoesNotExposeCoordinates() async throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "travel-tools-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
        let config = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [config])
        let chat = ButlerChat(container: container,
            reminders: ReminderStore(file: dir.appendingPathComponent("reminders.json"), schedules: false),
            connection: SubscriptionConnection(keychainAccount: suite), directory: dir, defaults: defaults)
        defer { withExtendedLifetime(chat) {} }
        let tools = try XCTUnwrap(chat.tools), device = FakeTravelDevice()
        tools.travel = TravelStore(file: dir.appendingPathComponent("places.json"), device: device)
        func call(_ name: String, _ args: [String: Any] = [:]) async throws -> String {
            await tools.execute(LocalToolCall(id: UUID().uuidString, name: name,
                arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
        }
        func privateCoordinatesAbsent(_ text: String) {
            XCTAssertFalse(text.contains("31.1234567")); XCTAssertFalse(text.contains("121.7654321"))
            XCTAssertFalse(text.contains("latitude")); XCTAssertFalse(text.contains("longitude"))
        }
        XCTAssertTrue(tools.toolJSON.contains("propose_place_reminder"))
        _ = try await call("get_travel_capabilities")
        _ = try await call("search_travel_places", ["query": "家", "near_id": NSNull()])
        XCTAssertEqual(device.searches, 0); XCTAssertEqual(device.fixes, 0)
        _ = try await call("propose_travel_access", ["allowed": true])
        _ = try await call("propose_travel_access", ["allowed": true])
        XCTAssertEqual(tools.pending.count, 1); XCTAssertTrue(tools.confirmAll().isEmpty)
        _ = await tools.confirmIncludingSystemChanges()
        let search = try await call("search_travel_places", ["query": "测试路73号", "near_id": NSNull()])
        privateCoordinatesAbsent(search)
        _ = try await call("propose_save_place", ["alias": "家", "point_id": device.result.id.uuidString, "existing_id": NSNull()])
        XCTAssertTrue(try tools.travel.places().isEmpty)
        privateCoordinatesAbsent(tools.pendingContext)
        let disk = try JSONDecoder().decode([PendingChange].self, from: Data(contentsOf: dir.appendingPathComponent("pending-changes.json")))
        XCTAssertTrue(disk.isEmpty)
        privateCoordinatesAbsent(await tools.confirmIncludingSystemChanges().joined())
        let home = try XCTUnwrap(tools.travel.places().first)
        _ = try await call("propose_place_reminder", ["place_id": home.id.uuidString, "text": "把肉放进冰箱", "radius_m": 230, "repeats": false])
        XCTAssertEqual(device.schedules, 0); XCTAssertEqual(device.grants, 0)
        privateCoordinatesAbsent(tools.pendingContext)
        privateCoordinatesAbsent(await tools.confirmIncludingSystemChanges().joined())
        XCTAssertEqual(device.schedules, 1); XCTAssertEqual(device.fixes, 0)
        privateCoordinatesAbsent(try await call("get_saved_places"))
        privateCoordinatesAbsent(try await call("get_place_reminders"))
        _ = await tools.confirmIncludingSystemChanges()
        XCTAssertEqual(device.schedules, 1)
    }
    func testNativeRequestIsEntryOnlyAndDoesNotUseTimedReminderNamespace() throws {
        let point = TravelPoint(name: "住宅", address: "测试路73号", latitude: 31.1234567, longitude: 121.7654321, timeZone: "Asia/Shanghai")
        let place = SavedPlace(id: UUID(), revision: 1, alias: "家", point: point)
        for repeats in [false, true] {
            let reminder = PlaceReminder(id: UUID(), place: place, text: "放进冰箱", radius: 230, repeats: repeats, state: .attempting)
            let request = AppleTravelDevice.notificationRequest(reminder)
            let trigger = try XCTUnwrap(request.trigger as? UNLocationNotificationTrigger)
            let region = try XCTUnwrap(trigger.region as? CLCircularRegion)
            XCTAssertTrue(region.notifyOnEntry); XCTAssertFalse(region.notifyOnExit)
            XCTAssertEqual(region.center.latitude, 31.1234567); XCTAssertEqual(region.center.longitude, 121.7654321)
            XCTAssertEqual(region.radius, 230); XCTAssertEqual(trigger.repeats, repeats)
            XCTAssertEqual(request.identifier, "butler.place.\(reminder.id.uuidString)")
            XCTAssertEqual(request.content.body, "放进冰箱")
            XCTAssertEqual(request.content.userInfo["placeReminderID"] as? String, reminder.id.uuidString)
        }
    }
    func testToolSchemasAreStrict() throws {
        let schemas = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[\(ButlerTools.travelTools)]".utf8)) as? [[String: Any]])
        XCTAssertEqual(schemas.count, 12)
        for schema in schemas {
            XCTAssertEqual(schema["strict"] as? Bool, true)
            let parameters = try XCTUnwrap(schema["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(parameters["required"] as? [String] ?? []), Set((parameters["properties"] as? [String: Any] ?? [:]).keys))
        }
    }
}
