import Foundation
import SwiftData
import XCTest
@testable import Butler

@MainActor
final class ButlerToolsTests: XCTestCase {
    private func makeTools() throws -> (ButlerTools, ModelContainer) {
        let configuration = ModelConfiguration(schema: ButlerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ButlerStore.schema, configurations: [configuration])
        let notesFile = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID()).json")
        let tools = ButlerTools(container: container, notes: try LocalMemoryStore(file: notesFile), jev: JevClient())
        return (tools, container)
    }

    private func call(_ tools: ButlerTools, _ name: String, _ arguments: String) async -> [String: Any] {
        let output = await tools.execute(LocalToolCall(id: UUID().uuidString, name: name, arguments: arguments))
        return (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }

    func testAddSearchAdjustAndCloseOnlyAfterConfirmation() async throws {
        let (tools, container) = try makeTools()
        let proposal = await call(tools, "propose_add_items", #"""
        {"items":[{"name":"牛奶","quantity":2,"unit":"瓶","storage":"冷藏","package_expiry":"2026-10-03","planned_use_by":null},
                  {"name":"草莓","quantity":1,"unit":"盒","storage":null,"package_expiry":null,"planned_use_by":null}]}
        """#)
        XCTAssertEqual(proposal["saved"] as? Bool, false)
        XCTAssertEqual(tools.pending.count, 2)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).isEmpty, "nothing saved before confirm")

        let receipts = tools.confirmAll()
        XCTAssertEqual(receipts.filter { $0.hasPrefix("✓") }.count, 2, receipts.joined())
        XCTAssertTrue(tools.pending.isEmpty)

        let found = await call(tools, "search_inventory", #"{"query":"牛奶 鸡蛋","include_finished":false}"#)
        let items = try XCTUnwrap(found["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["storage"] as? String, "冷藏")
        XCTAssertEqual(items.first?["governing_date"] as? String, "2026-10-03")
        let milkID = try XCTUnwrap(items.first?["lot_id"] as? String)

        _ = await call(tools, "propose_set_quantity", #"{"lot_id":"\#(milkID)","quantity":1}"#)
        _ = await call(tools, "propose_move", #"{"lot_id":"\#(milkID)","location":"冷冻"}"#)
        XCTAssertEqual(tools.confirmAll().filter { $0.hasPrefix("✓") }.count, 2)
        let milk = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryLot>()).first { $0.id.uuidString == milkID })
        XCTAssertEqual(milk.quantity, 1)
        XCTAssertEqual(milk.storageLocation, "冷冻")

        _ = await call(tools, "propose_close", #"{"lot_id":"\#(milkID)","reason":"used_up"}"#)
        XCTAssertEqual(tools.confirmAll().first?.hasPrefix("✓"), true)
        let all = await call(tools, "search_inventory", #"{"query":"","include_finished":true}"#)
        XCTAssertEqual(all["count"] as? Int, 1)
        XCTAssertEqual((all["finished"] as? [[String: Any]])?.count, 1)
    }

    func testBadArgumentsAreReportedNotSaved() async throws {
        let (tools, _) = try makeTools()
        let unknownLot = await call(tools, "propose_set_quantity", #"{"lot_id":"\#(UUID().uuidString)","quantity":1}"#)
        XCTAssertNotNil(unknownLot["error"])
        let badDate = await call(tools, "propose_add_items",
            #"{"items":[{"name":"面包","quantity":1,"unit":"袋","storage":null,"package_expiry":"十月三号","planned_use_by":null}]}"#)
        XCTAssertNotNil(badDate["error"])
        XCTAssertTrue(tools.pending.isEmpty)
    }

    func testNotesAreRememberedAfterConfirmation() async throws {
        let (tools, _) = try makeTools()
        _ = await call(tools, "propose_note", #"{"id":null,"title":"买菜习惯","text":"周末去盒马买菜"}"#)
        XCTAssertTrue(tools.notes.records.isEmpty)
        _ = tools.confirmAll()
        let found = await tools.execute(LocalToolCall(id: "n", name: "search_notes", arguments: #"{"query":"盒马"}"#))
        XCTAssertTrue(found.contains("周末去盒马买菜"))
    }

    func testJevToolOnlyOfferedWithKey() throws {
        let (tools, _) = try makeTools()
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(tools.toolJSON.utf8)) as? [Any])
        XCTAssertEqual(tools.toolJSON.contains("judge_with_jev"), tools.jev.isConfigured)
    }
}
