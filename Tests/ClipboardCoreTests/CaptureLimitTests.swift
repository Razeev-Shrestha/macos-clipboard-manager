import AppKit
import Foundation
import XCTest
@testable import ClipboardCore

@MainActor
final class CaptureLimitTests: XCTestCase {
    func testPayloadAboveCaptureLimitIsSkipped() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard, maximumCaptureBytes: 1_024)

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString(String(repeating: "x", count: 4_096), forType: .string))

        XCTAssertEqual(
            boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount),
            .skipped(.tooLarge)
        )
    }

    func testPayloadWithinCaptureLimitIsCaptured() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard, maximumCaptureBytes: 1_024)

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("synthetic small capture", forType: .string))

        guard case .snapshot(let snapshot) = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount) else {
            XCTFail("expected a snapshot within the limit")
            return
        }
        XCTAssertEqual(snapshot.capture.payload.plainText, "synthetic small capture")
    }

    func testSearchableTextIsBoundedButPayloadKeepsFullText() {
        let longText = String(repeating: "a", count: ClipboardCapture.maximumSearchableCharacters + 500)
        let payload = ClipboardPayload(
            primaryTypeIdentifier: "public.utf8-plain-text",
            representations: [ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data(longText.utf8))],
            plainText: longText
        )
        let capture = ClipboardCapture(payload: payload, primaryType: .text)

        XCTAssertEqual(capture.searchableText?.count, ClipboardCapture.maximumSearchableCharacters)
        XCTAssertEqual(capture.payload.plainText, longText)
    }
}
