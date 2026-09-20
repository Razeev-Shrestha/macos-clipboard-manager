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
        XCTAssertEqual(store.value.appearance, .system)
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
            animationsEnabled: false,
            appearance: .dark,
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

    func testLegacySettingsDefaultAppearanceAndAnimationsAndPreservePreferences() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = #"{"retention":{"maximumUnpinnedItems":42,"maximumUnpinnedAge":604800},"recordingPaused":true,"excludedBundleIdentifiers":["com.example.passwords"],"menuBarVisible":false,"launchAtLogin":true}"#
        defaults.set(Data(legacy.utf8), forKey: ClipboardSettingsStore.settingsKey)

        let store = ClipboardSettingsStore(defaults: defaults)

        XCTAssertNil(store.error)
        XCTAssertTrue(store.value.animationsEnabled)
        XCTAssertEqual(store.value.appearance, .system)
        XCTAssertEqual(store.value.retention.maximumUnpinnedItems, 42)
        XCTAssertEqual(store.value.retention.maximumUnpinnedAge, 7 * 24 * 60 * 60)
        XCTAssertTrue(store.value.recordingPaused)
        XCTAssertEqual(store.value.excludedBundleIdentifiers, ["com.example.passwords"])
        XCTAssertFalse(store.value.menuBarVisible)
        XCTAssertTrue(store.value.launchAtLogin)
        XCTAssertEqual(store.value.globalShortcut, .default)

        store.update {
            $0.animationsEnabled = false
            $0.appearance = .light
        }
        let reopened = ClipboardSettingsStore(defaults: defaults)
        XCTAssertFalse(reopened.value.animationsEnabled)
        XCTAssertEqual(reopened.value.appearance, .light)
        XCTAssertEqual(reopened.value, store.value)
        XCTAssertNil(reopened.error)
    }

    func testRetentionAgeUpdatesPersistAndNotifyRuntimeWithoutChangingOtherPreferences() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ClipboardSettingsStore(defaults: defaults)
        store.update {
            $0.retention.maximumUnpinnedItems = 250
            $0.excludedBundleIdentifiers = ["com.example.passwords"]
            $0.animationsEnabled = false
        }
        var changes: [ClipboardManagerSettings] = []
        store.onChange = { changes.append($0) }

        for days in [1, 7, 30, 90] {
            let age = TimeInterval(days * 24 * 60 * 60)
            store.update { $0.retention.maximumUnpinnedAge = age }
            let reopened = ClipboardSettingsStore(defaults: defaults)

            XCTAssertNil(reopened.error)
            XCTAssertEqual(reopened.value.retention.maximumUnpinnedAge, age)
            XCTAssertEqual(changes.last?.repositoryRetention.maximumUnpinnedAge, age)
            XCTAssertEqual(reopened.value.retention.maximumUnpinnedItems, 250)
            XCTAssertEqual(reopened.value.excludedBundleIdentifiers, ["com.example.passwords"])
            XCTAssertFalse(reopened.value.animationsEnabled)
        }
        XCTAssertEqual(changes.count, 4)
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
