import AppKit
import XCTest
@testable import ClipboardCore

@MainActor
final class ClipboardTextClassifierTests: XCTestCase {
    func testRecognizesObviousDeveloperContent() {
        let examples = [
            "{\"name\": \"clipboard\", \"enabled\": true}",
            "[\"one\", 2, false]",
            "npm run dev",
            "git checkout -b classifier",
            "docker compose up",
            "const request = await fetch(endpoint)",
            "func copyToPasteboard(_ text: String) {\n    print(text)\n}",
            "def normalize(value):\n    return value.strip()"
        ]

        for example in examples {
            XCTAssertTrue(ClipboardTextClassifier.isLikelyCode(example), example)
        }
    }

    func testKeepsEverydayTextURLsAndLooseWordsAsText() {
        let examples = [
            "Let me know when you arrive.",
            "42",
            "https://example.invalid/docs?topic=code",
            "I ran into git at the museum.",
            "Please import the report before lunch.",
            "A short note, with punctuation!"
        ]

        for example in examples {
            XCTAssertFalse(ClipboardTextClassifier.isLikelyCode(example), example)
        }
    }

    func testNamedPrivatePasteboardClassifiesCodeWithoutChangingRepresentationsOrSource() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let source = ClipboardSource(appName: "Terminal", bundleIdentifier: "com.apple.Terminal")
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard, sourceProvider: { source })
        let text = "npm run dev"

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString(text, forType: .string))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = result else {
            XCTFail("expected a code snapshot")
            return
        }

        XCTAssertEqual(snapshot.capture.primaryType, .code)
        XCTAssertEqual(snapshot.capture.source, source)
        XCTAssertEqual(snapshot.capture.payload.plainText, text)
        XCTAssertEqual(snapshot.capture.payload.representations, [
            ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
        ])
    }
}
