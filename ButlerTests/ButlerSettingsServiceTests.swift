import XCTest
@testable import Butler

@MainActor
final class ButlerSettingsServiceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "ButlerSettingsServiceTests.\(UUID().uuidString)"
        let result = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return result
    }

    func testSnapshotContainsOnlyAllowlistedSettingsAndNeverCredentials() {
        let store = defaults()
        store.set("a-secret-value", forKey: "jevAPIKey")
        store.set("another-secret-value", forKey: "accessToken")
        store.set("yet-another-secret-value", forKey: "refreshToken")
        let snapshot = ButlerSettingsService.snapshot(defaults: store)
        XCTAssertEqual(Set(snapshot.compactMap { $0["key"] }), Set(ButlerSettingsService.definitions.map(\.key)))
        XCTAssertFalse(String(describing: snapshot).contains("secret-value"))
        XCTAssertThrowsError(try ButlerSettingsService.proposal(key: "jevAPIKey", value: "replace", defaults: store))
        XCTAssertThrowsError(try ButlerSettingsService.proposal(key: "accessToken", value: "replace", defaults: store))
    }

    func testProposalDoesNotWriteAndApplyPreservesNativeTypes() throws {
        let store = defaults()
        // Suites still see the process registration domain (including AppStorage defaults).
        // Compare explicit original values rather than assuming a missing object is nil.
        store.set("light", forKey: "appearanceMode")
        store.set("mist", forKey: "appTheme")
        store.set(540, forKey: "reminderMinutes")
        let changes = try [
            ButlerSettingsService.proposal(key: "appearanceMode", value: "dark", defaults: store),
            ButlerSettingsService.proposal(key: "appTheme", value: "plain", defaults: store),
            ButlerSettingsService.proposal(key: "reminderMinutes", value: "1234", defaults: store)
        ]
        XCTAssertEqual(store.string(forKey: "appearanceMode"), "light")
        XCTAssertEqual(store.string(forKey: "appTheme"), "mist")
        XCTAssertEqual(store.object(forKey: "reminderMinutes") as? Int, 540)
        try ButlerSettingsService.apply(changes, defaults: store, jev: nil)
        XCTAssertEqual(store.string(forKey: "appearanceMode"), "dark")
        XCTAssertEqual(store.string(forKey: "appTheme"), "plain")
        XCTAssertEqual(store.object(forKey: "reminderMinutes") as? Int, 1234)
    }

    func testStaleBatchRejectsBeforeWritingAnySetting() throws {
        let store = defaults()
        let changes = try [
            ButlerSettingsService.proposal(key: "appearanceMode", value: "dark", defaults: store),
            ButlerSettingsService.proposal(key: "accentChoice", value: "ocean", defaults: store)
        ]
        store.set("berry", forKey: "accentChoice")
        XCTAssertThrowsError(try ButlerSettingsService.apply(changes, defaults: store, jev: nil))
        XCTAssertNil(store.object(forKey: "appearanceMode"), "Earlier values in the same batch must not be partially written")
        XCTAssertEqual(store.string(forKey: "accentChoice"), "berry")
    }

    func testInvalidValuesAndDuplicateKeysAreRejected() throws {
        let store = defaults()
        for (key, value) in [("appearanceMode", "purple"), ("appTheme", "rainbow"),
                             ("reminderMinutes", "-1"), ("reminderMinutes", "1440"),
                             ("expiryWarningDays", "999"), ("butlerProfile", String(repeating: "字", count: 4001))] {
            XCTAssertThrowsError(try ButlerSettingsService.proposal(key: key, value: value, defaults: store), key)
        }
        let change = try ButlerSettingsService.proposal(key: "appearanceMode", value: "dark", defaults: store)
        XCTAssertThrowsError(try ButlerSettingsService.apply([change, change], defaults: store, jev: nil))
        XCTAssertNil(store.object(forKey: "appearanceMode"))
    }

    func testDefaultSnapshotMatchesExistingNativeControlDefaults() {
        let store = defaults()
        let values = Dictionary(uniqueKeysWithValues: ButlerSettingsService.snapshot(defaults: store).map { ($0["key"]!, $0["value"]!) })
        XCTAssertEqual(values["appearanceMode"], AppearanceMode.system.rawValue)
        XCTAssertEqual(values["accentChoice"], AccentChoice.glass.rawValue)
        XCTAssertEqual(values["reminderMinutes"], "540")
        XCTAssertEqual(values["expiryWarningDays"], "2")
        XCTAssertEqual(values["jevEnabled"], "true")
        XCTAssertEqual(values["jevPrefetchEnabled"], "true")
    }
}
