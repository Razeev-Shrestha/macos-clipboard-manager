import AppKit
import Foundation
import XCTest
@testable import ClipboardCore

@MainActor
final class RichPasteboardBoundaryTests: XCTestCase {
    func testOrderedFileItemsRoundTripWithSearchableNames() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

        let firstURL = fixtureRoot.appendingPathComponent("synthetic-report.txt")
        let secondURL = fixtureRoot.appendingPathComponent("synthetic-folder", isDirectory: true)
        try Data("fixture".utf8).write(to: firstURL)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let firstItem = try makeFileItem(url: firstURL)
        let secondItem = try makeFileItem(url: secondURL)
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = result,
              let items = snapshot.capture.payload.items
        else {
            XCTFail("expected an ordered multi-item capture")
            return
        }

        XCTAssertEqual(snapshot.capture.primaryType, .files)
        XCTAssertEqual(items.map { $0.url }, [firstURL, secondURL])
        XCTAssertEqual(snapshot.capture.searchableText, "synthetic-report.txt synthetic-folder")
        XCTAssertEqual(items.map(\.primaryTypeIdentifier), Array(repeating: NSPasteboard.PasteboardType.fileURL.rawValue, count: 2))

        guard case .written(let changeCount) = boundary.write(payload: snapshot.capture.payload) else {
            XCTFail("expected a multi-item restore")
            return
        }
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) }, [firstURL.absoluteString, secondURL.absoluteString])

        let receiptChangeCount = changeCount
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("synthetic replacement", forType: .string))
        XCTAssertNotEqual(receiptChangeCount, pasteboard.changeCount)
    }

    func testRTFAndPlainTextKeepBothRepresentationsWithoutDecodingRTF() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let rtf = Data("{\\rtf1\\ansi synthetic rich fixture}".utf8)
        let plainText = "synthetic rich fixture"
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(rtf, forType: .rtf))
        XCTAssertTrue(item.setString(plainText, forType: .string))
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = result else {
            XCTFail("expected a rich-text capture")
            return
        }

        XCTAssertNil(snapshot.capture.payload.items)
        XCTAssertEqual(snapshot.capture.primaryType, .richText)
        XCTAssertEqual(snapshot.capture.payload.plainText, plainText)
        XCTAssertEqual(representationData(.rtf, in: snapshot.capture.payload.representations), rtf)
        XCTAssertEqual(representationData(.string, in: snapshot.capture.payload.representations), Data(plainText.utf8))

        XCTAssertNotEqual(boundary.write(payload: snapshot.capture.payload), .failed)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), plainText)
    }

    func testPNGAndTIFFRoundTripAsOpaqueBytes() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let tiff = Data([0x49, 0x49, 0x2a, 0x00, 0x08, 0x00])
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(png, forType: .png))
        XCTAssertTrue(item.setData(tiff, forType: .tiff))
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = result else {
            XCTFail("expected an image capture")
            return
        }
        XCTAssertEqual(snapshot.capture.primaryType, .image)
        XCTAssertEqual(representationData(.png, in: snapshot.capture.payload.representations), png)
        XCTAssertEqual(representationData(.tiff, in: snapshot.capture.payload.representations), tiff)

        XCTAssertNotEqual(boundary.write(payload: snapshot.capture.payload), .failed)
        let restored = pasteboard.pasteboardItems?.first
        XCTAssertEqual(restored?.data(forType: .png), png)
        XCTAssertEqual(restored?.data(forType: .tiff), tiff)
    }

    func testTextFallbackRetainsPlainURLMetadataWhenURLRepresentationIsMalformed() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let plainURL = "https://example.invalid/synthetic-fallback"
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data([0xff, 0x00]), forType: .URL))
        XCTAssertTrue(item.setString(plainURL, forType: .string))
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = result else {
            XCTFail("expected the valid text fallback")
            return
        }
        XCTAssertEqual(snapshot.capture.primaryType, .url)
        XCTAssertEqual(snapshot.capture.payload.primaryTypeIdentifier, NSPasteboard.PasteboardType.string.rawValue)
        XCTAssertEqual(snapshot.capture.payload.plainText, plainURL)
        XCTAssertEqual(snapshot.capture.payload.url?.absoluteString, plainURL)
        XCTAssertEqual(representationData(.string, in: snapshot.capture.payload.representations), Data(plainURL.utf8))
        XCTAssertNil(representationData(.URL, in: snapshot.capture.payload.representations))
    }

    func testPlainTextURLWithCopiedWhitespaceIsRecognizedAsLink() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let copiedURL = "  https://example.invalid/copied-link  \n"

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString(copiedURL, forType: .string))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = result else {
            XCTFail("expected a plain-text URL snapshot")
            return
        }
        XCTAssertEqual(snapshot.capture.primaryType, .url)
        XCTAssertEqual(snapshot.capture.payload.url?.absoluteString, "https://example.invalid/copied-link")
    }

    func testImageContentOutranksURLAndPlainTextRepresentations() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        let url = "https://example.invalid/synthetic-caption"
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(image, forType: .png))
        XCTAssertTrue(item.setString(url, forType: .URL))
        XCTAssertTrue(item.setString("synthetic image caption", forType: .string))
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = result else {
            XCTFail("expected an image capture")
            return
        }
        XCTAssertEqual(snapshot.capture.primaryType, .image)
        XCTAssertEqual(snapshot.capture.payload.primaryTypeIdentifier, NSPasteboard.PasteboardType.png.rawValue)
        XCTAssertEqual(snapshot.capture.payload.url?.absoluteString, url)
        XCTAssertEqual(snapshot.capture.payload.plainText, "synthetic image caption")
    }

    func testPrivacyAndExcludedSourcePreflightRejectsAllItems() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let concealed = NSPasteboardItem()
        XCTAssertTrue(concealed.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardPrivacyMarkers.concealed)))
        XCTAssertTrue(concealed.setString("synthetic concealed fixture", forType: .string))
        let visible = NSPasteboardItem()
        XCTAssertTrue(visible.setString("synthetic visible fixture", forType: .string))
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.writeObjects([visible, concealed]))

        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        XCTAssertEqual(boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount), .skipped(.privacyMarker))

        let sourceMarker = NSPasteboardItem()
        let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
        XCTAssertTrue(sourceMarker.setString("com.example.synthetic-first", forType: sourceType))
        XCTAssertTrue(sourceMarker.setString("synthetic excluded fixture", forType: .string))
        let secondSourceMarker = NSPasteboardItem()
        XCTAssertTrue(secondSourceMarker.setString("com.example.synthetic-excluded", forType: sourceType))
        XCTAssertTrue(secondSourceMarker.setString("synthetic second source fixture", forType: .string))
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.writeObjects([sourceMarker, secondSourceMarker]))
        let mismatchedSourceBoundary = NSPasteboardBoundary(
            pasteboard: pasteboard,
            sourceProvider: { ClipboardSource(appName: "Different Foreground App", bundleIdentifier: "com.example.other") }
        )
        guard case .snapshot(let sourceSnapshot) = mismatchedSourceBoundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount) else {
            XCTFail("expected a source-marked capture")
            return
        }
        XCTAssertEqual(sourceSnapshot.capture.source?.bundleIdentifier, "com.example.synthetic-first")
        XCTAssertNil(sourceSnapshot.capture.source?.appName)

        let excludedBoundary = NSPasteboardBoundary(
            pasteboard: pasteboard,
            sourceProvider: { ClipboardSource(appName: "Different Foreground App", bundleIdentifier: "com.example.other") }
        )
        excludedBoundary.setExcludedBundleIdentifiers(["com.example.synthetic-excluded"])
        XCTAssertEqual(excludedBoundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount), .skipped(.privacyMarker))
    }

    func testLegacyPayloadDecodesAndRetainsItsExistingIdentity() throws {
        let encoded = Data("""
        {"primaryTypeIdentifier":"public.utf8-plain-text","representations":[{"typeIdentifier":"public.utf8-plain-text","data":"bGVnYWN5"}],"availableTypeIdentifiers":["public.utf8-plain-text"],"plainText":"legacy"}
        """.utf8)
        let payload = try JSONDecoder().decode(ClipboardPayload.self, from: encoded)

        XCTAssertNil(payload.items)
        XCTAssertEqual(
            ClipboardHasher.identity(for: payload),
            "386340b9fbf597980168f56df77efc1548c4a16a45e620d46536d64e2616b025"
        )
    }

    func testMultiItemIdentityIncludesItemOrder() {
        let first = ClipboardPayloadItem(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            representations: [ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: Data("first".utf8))],
            plainText: "first"
        )
        let second = ClipboardPayloadItem(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            representations: [ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: Data("second".utf8))],
            plainText: "second"
        )
        let ordered = ClipboardPayload(
            primaryTypeIdentifier: first.primaryTypeIdentifier,
            representations: first.representations,
            plainText: first.plainText,
            items: [first, second]
        )
        let reversed = ClipboardPayload(
            primaryTypeIdentifier: second.primaryTypeIdentifier,
            representations: second.representations,
            plainText: second.plainText,
            items: [second, first]
        )

        XCTAssertNotEqual(ClipboardHasher.identity(for: ordered), ClipboardHasher.identity(for: reversed))
    }

    func testMultiItemIdentityDelimitsEachItem() {
        let firstLayout = ClipboardPayload(
            primaryTypeIdentifier: "one",
            representations: [ClipboardRepresentation(typeIdentifier: "two", data: Data("three".utf8))],
            items: [
                ClipboardPayloadItem(
                    primaryTypeIdentifier: "one",
                    representations: [ClipboardRepresentation(typeIdentifier: "two", data: Data("three".utf8))]
                ),
                ClipboardPayloadItem(primaryTypeIdentifier: "four", representations: [])
            ]
        )
        let secondLayout = ClipboardPayload(
            primaryTypeIdentifier: "one",
            representations: [],
            items: [
                ClipboardPayloadItem(primaryTypeIdentifier: "one", representations: []),
                ClipboardPayloadItem(
                    primaryTypeIdentifier: "two",
                    representations: [ClipboardRepresentation(typeIdentifier: "three", data: Data("four".utf8))]
                )
            ]
        )

        XCTAssertNotEqual(ClipboardHasher.identity(for: firstLayout), ClipboardHasher.identity(for: secondLayout))
    }

    private func makeFileItem(url: URL) throws -> NSPasteboardItem {
        let item = NSPasteboardItem()
        guard item.setString(url.absoluteString, forType: .fileURL) else {
            throw NSError(domain: "RichPasteboardBoundaryTests", code: 1)
        }
        return item
    }

    private func representationData(
        _ type: NSPasteboard.PasteboardType,
        in representations: [ClipboardRepresentation]
    ) -> Data? {
        representations.first(where: { $0.typeIdentifier == type.rawValue })?.data
    }
}
