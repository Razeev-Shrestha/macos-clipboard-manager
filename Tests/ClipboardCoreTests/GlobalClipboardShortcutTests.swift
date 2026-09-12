import Carbon.HIToolbox
import XCTest
@testable import ClipboardCore

@MainActor
final class GlobalClipboardShortcutTests: XCTestCase {
    func testDefaultIsCommandShiftV() {
        let configuration = GlobalClipboardShortcutConfiguration.default

        XCTAssertEqual(configuration.keyCode, 9)
        XCTAssertEqual(configuration.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertTrue(configuration.isValid)
    }

    func testConfigurationRoundTripsAndRejectsInvalidValues() throws {
        let configuration = GlobalClipboardShortcutConfiguration(keyCode: 12, modifiers: 0x0002)
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(GlobalClipboardShortcutConfiguration.self, from: data)

        XCTAssertEqual(decoded, configuration)
        XCTAssertFalse(GlobalClipboardShortcutConfiguration(keyCode: 128, modifiers: 0x0003).isValid)
        XCTAssertFalse(GlobalClipboardShortcutConfiguration(keyCode: 12, modifiers: 0).isValid)
        XCTAssertFalse(GlobalClipboardShortcutConfiguration(keyCode: 12, modifiers: 0x8000).isValid)
    }

    func testInvalidConfigurationFailsBeforeCarbonRegistration() {
        let shortcut = GlobalClipboardShortcut(
            configuration: GlobalClipboardShortcutConfiguration(keyCode: 128, modifiers: 0x0003)
        )

        XCTAssertThrowsError(try shortcut.register()) { error in
            XCTAssertEqual(error as? GlobalClipboardShortcutError, .invalidConfiguration)
        }
    }
}
