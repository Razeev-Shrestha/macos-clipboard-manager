import Foundation
import XCTest
@testable import ClipboardCore

@MainActor
final class ClipboardSettingsTests: XCTestCase {
    func testAbsentSettingsUseDefaultsWithoutError() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ClipboardSettingsStore(defaults: defaults)

        XCTAssertEqual(store.value, .default)
        XCTAssertNil(store.error)
    }

    func testSettingsRoundTripAndChangeCallback() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = GlobalClipboardShortcutConfiguration(
            keyCode: 12,
            modifiers: GlobalClipboardShortcutConfiguration.default.modifiers
        )
        let expected = ClipboardManagerSettings(
            retention: ClipboardRetentionSettings(maximumUnpinnedItems: 42, maximumUnpinnedAge: 900),
            recordingPaused: true,
            excludedBundleIdentifiers: ["com.example.passwords"],
            menuBarVisible: false,
            launchAtLogin: true,
            globalShortcut: shortcut
        )
        let store = ClipboardSettingsStore(defaults: defaults)
        var changes: [ClipboardManagerSettings] = []
        store.onChange = { changes.append($0) }

        store.update(expected)
        let reopened = ClipboardSettingsStore(defaults: defaults)

        XCTAssertEqual(store.value, expected)
        XCTAssertEqual(reopened.value, expected)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(changes, [expected])
    }

    func testInvalidStoredSettingsPauseAndRecoverExclusions() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformed = #"{"retention":{"maximumUnpinnedItems":-1,"maximumUnpinnedAge":2592000},"recordingPaused":false,"excludedBundleIdentifiers":["com.example.passwords"],"menuBarVisible":true,"launchAtLogin":false,"globalShortcut":{"keyCode":9,"modifiers":3}}"#
        defaults.set(Data(malformed.utf8), forKey: ClipboardSettingsStore.settingsKey)

        let store = ClipboardSettingsStore(defaults: defaults)

        XCTAssertEqual(store.error, .invalidStoredSettings)
        XCTAssertTrue(store.value.recordingPaused)
        XCTAssertEqual(store.value.excludedBundleIdentifiers, ["com.example.passwords"])
    }

    func testInvalidUpdatePreservesCurrentExclusionsAndPausesRecording() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ClipboardSettingsStore(defaults: defaults)
        store.update { settings in
            settings.excludedBundleIdentifiers = ["com.example.passwords"]
        }

        store.update { settings in
            settings.retention.maximumUnpinnedItems = -1
        }

        XCTAssertTrue(store.value.recordingPaused)
        XCTAssertEqual(store.value.excludedBundleIdentifiers, ["com.example.passwords"])
        XCTAssertEqual(store.error, .invalidStoredSettings)
    }

    func testWrongTypeStoredValueFailsClosedAndRecoversExclusions() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = ClipboardSettingsStore(defaults: defaults)
        initial.update { settings in
            settings.excludedBundleIdentifiers = ["com.example.passwords"]
        }

        // UserDefaults can contain a value written by another version or API.
        // A present non-Data value is corruption, not an absent setting.
        defaults.set("not encoded settings", forKey: ClipboardSettingsStore.settingsKey)
        let store = ClipboardSettingsStore(defaults: defaults)

        XCTAssertEqual(store.error, .invalidStoredSettings)
        XCTAssertTrue(store.value.recordingPaused)
        XCTAssertEqual(store.value.excludedBundleIdentifiers, ["com.example.passwords"])
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ClipboardSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
