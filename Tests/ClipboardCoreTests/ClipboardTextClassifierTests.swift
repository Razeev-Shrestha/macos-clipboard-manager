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

    func testBoundaryKeepsRawTextAndControllerPersistsCodeWithoutChangingPayloadOrSource() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTextClassifierTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let source = ClipboardSource(appName: "Terminal", bundleIdentifier: "com.apple.Terminal")
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard, sourceProvider: { source })
        let text = "npm run dev"
        let controller = ClipboardHistoryController(
            pasteboard: boundary,
            databaseURL: directoryURL.appendingPathComponent("history.sqlite")
        )
        await controller.start()

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString(text, forType: .string))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = result else {
            XCTFail("expected a text snapshot")
            await controller.shutdown()
            return
        }

        // Pasteboard reading is the main-actor native boundary. Classification and
        // hashing happen later in ClipboardHistoryController's utility worker.
        XCTAssertEqual(snapshot.capture.primaryType, .text)
        XCTAssertEqual(snapshot.capture.source, source)
        XCTAssertEqual(snapshot.capture.payload.plainText, text)
        let expectedRepresentations = [
            ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
        ]
        XCTAssertEqual(snapshot.capture.payload.representations, expectedRepresentations)

        guard case .captured = controller.pollNow() else {
            XCTFail("expected the controller to accept the changed pasteboard")
            await controller.shutdown()
            return
        }
        await controller.flush()

        guard let metadata = controller.items.first else {
            XCTFail("expected a durable metadata row")
            await controller.shutdown()
            return
        }
        XCTAssertEqual(metadata.primaryType, .code)
        XCTAssertEqual(metadata.sourceAppName, source.appName)
        XCTAssertEqual(metadata.sourceBundleID, source.bundleIdentifier)

        let hydrated = try await controller.loadItem(id: metadata.id)
        XCTAssertEqual(hydrated?.primaryType, .code)
        XCTAssertEqual(hydrated?.sourceAppName, source.appName)
        XCTAssertEqual(hydrated?.sourceBundleID, source.bundleIdentifier)
        XCTAssertEqual(hydrated?.payload?.plainText, snapshot.capture.payload.plainText)
        XCTAssertEqual(hydrated?.payload?.representations, expectedRepresentations)
        await controller.shutdown()
    }
}
