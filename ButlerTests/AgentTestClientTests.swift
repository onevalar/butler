import Foundation
import XCTest
@testable import Butler

@MainActor
final class AgentTestClientTests: XCTestCase {
    func testConnectionRejectsPublicHTTPAndEmbeddedCredentials() {
        XCTAssertNotNil(AgentTestClient.baseURL("https://example.com/butler"))
        XCTAssertNotNil(AgentTestClient.baseURL("http://localhost:8787"))
        XCTAssertNil(AgentTestClient.baseURL("http://example.com"))
        XCTAssertNil(AgentTestClient.baseURL("https://user:secret@example.com"))
        XCTAssertNil(AgentTestClient.baseURL("https://example.com?token=secret"))
        XCTAssertNil(AgentTestClient.baseURL("file:///tmp/store"))
    }

    func testStateDecodesIdlessPreviewAndUnknownExpiryWithoutInventingDate() throws {
        let json = #"{"model":"gpt-6-sol","reasoningEffort":"medium","fictional":true,"busy":false,"records":[],"messages":[],"proposal":{"id":"preview","before":null,"after":{"kind":"batch","subject":"麻薯","shop":"盒马","quantity":6,"unit":"个","location":"冰箱上层","expiryDate":null}}}"#
        let value = try JSONDecoder().decode(AgentTestState.self, from: Data(json.utf8))
        let after = try XCTUnwrap(value.proposal?.after)
        XCTAssertNil(after.id)
        XCTAssertEqual(after.quantity, 6)
        XCTAssertEqual(after.title, "盒马 · 麻薯")
        XCTAssertTrue(after.detail.contains("到期日：未提供"))
        XCTAssertNil(value.proposal?.before)
    }

    func testNoteDetailDoesNotPresentHabitAsInventory() throws {
        let json = #"{"id":"note","kind":"note","subject":"麻薯","shop":"盒马","text":"通常买6个，放冰箱下层"}"#
        let note = try JSONDecoder().decode(AgentMemory.self, from: Data(json.utf8))
        XCTAssertEqual(note.detail, "通常买6个，放冰箱下层")
        XCTAssertNil(note.quantity)
        XCTAssertFalse(note.detail.contains("到期日"))
    }
}
