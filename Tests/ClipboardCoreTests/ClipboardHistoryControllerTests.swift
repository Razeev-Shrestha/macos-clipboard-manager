import Foundation
import XCTest
@testable import ClipboardCore

@MainActor
private final class ControllerPasteboard: ClipboardPasteboard {
    var changeCount = 0
    var accessState: PasteboardAccessState = .allowed
    var snapshots: [Int: PasteboardReadResult] = [:]

    func readSnapshotIfStable(expectedChangeCount: Int) -> PasteboardReadResult {
        snapshots[expectedChangeCount] ?? .skipped(.empty)
    }

    func write(payload: ClipboardPayload) -> PasteboardWriteResult {
        .failed
    }

    func record(_ capture: ClipboardCapture) {
        changeCount += 1
        snapshots[changeCount] = .snapshot(PasteboardSnapshot(changeCount: changeCount, capture: capture))
    }
}

@MainActor
final class ClipboardHistoryControllerTests: XCTestCase {
    func testControllerPersistsCaptureThroughShutdownAndReopen() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, databaseURL: fixture.databaseURL)
        await controller.start()
        XCTAssertEqual(controller.storageState, .ready)

        pasteboard.record(makeCapture(text: "synthetic controller persistence"))
        _ = controller.pollNow()
        await controller.shutdown()

        let reopened = ClipboardHistoryController(
            pasteboard: ControllerPasteboard(),
            databaseURL: fixture.databaseURL
        )
        await reopened.start()
        XCTAssertEqual(reopened.storageState, .ready)
        XCTAssertEqual(reopened.items.map(\.searchableText), ["synthetic controller persistence"])
        XCTAssertNil(reopened.items.first?.payload)
        await reopened.shutdown()
    }

    func testCaptureDuringActiveSearchUsesDurableCurrentQueryResults() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, databaseURL: fixture.databaseURL)
        await controller.start()

        pasteboard.record(makeCapture(text: "synthetic alpha row"))
        _ = controller.pollNow()
        await controller.flush()

        controller.query = "synthetic beta"
        controller.query = "synthetic fresh"
        pasteboard.record(makeCapture(text: "synthetic fresh row"))
        _ = controller.pollNow()
        await controller.flush()

        XCTAssertEqual(controller.query, "synthetic fresh")
        XCTAssertEqual(controller.items.map(\.searchableText), ["synthetic fresh row"])
        controller.filter = .text
        await controller.flush()
        XCTAssertEqual(controller.items.map(\.searchableText), ["synthetic fresh row"])
        await controller.shutdown()
    }

    func testPersistedCanonicalIdentityAndPinOutliveMonitorCache() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()
        let stored = try await repository.record(makeItem(text: "synthetic canonical item"))
        _ = try await repository.setPinned(true, for: stored.id)
        await repository.close()

        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, databaseURL: fixture.databaseURL)
        await controller.start()
        let duplicateCapture = makeCapture(text: "synthetic canonical item")
        let duplicate = ClipboardItem(capture: duplicateCapture, createdAt: Date())
        XCTAssertEqual(duplicate.contentHash, stored.contentHash)
        pasteboard.record(duplicateCapture)
        _ = controller.pollNow()
        await controller.flush()

        XCTAssertEqual(controller.items.count, 1)
        XCTAssertEqual(controller.items.first?.id, stored.id)
        XCTAssertTrue(controller.items.first?.isPinned == true)
        await controller.shutdown()
    }

    func testStorageOpenFailureDoesNotStartMonitoringAndShutdownRemainsSafe() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }
        try Data("not a directory".utf8).write(to: fixture.directoryURL.appendingPathComponent("blocked"))

        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(
            pasteboard: pasteboard,
            databaseURL: fixture.directoryURL.appendingPathComponent("blocked/history.sqlite")
        )
        await controller.start()
        XCTAssertEqual(controller.storageState, .failed)

        pasteboard.record(makeCapture(text: "synthetic unsaved item"))
        _ = controller.pollNow()
        await controller.shutdown()
        XCTAssertEqual(controller.storageState, .inactive)
    }

    func testPostStartWriteFailurePausesRecordingWithoutPublishingAnUnsavedRow() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, repository: repository)
        await controller.start()
        XCTAssertEqual(controller.storageState, .ready)

        await repository.close()
        pasteboard.record(makeCapture(text: "synthetic unsaved post-start item"))
        _ = controller.pollNow()
        await controller.flush()

        XCTAssertEqual(controller.storageState, .failed)
        XCTAssertTrue(controller.items.isEmpty)

        controller.query = "synthetic"
        controller.filter = .text
        await controller.flush()
        XCTAssertEqual(controller.storageState, .failed)
        XCTAssertTrue(controller.items.isEmpty)
        await controller.shutdown()
    }

    private func makeCapture(text: String) -> ClipboardCapture {
        let payload = ClipboardPayload(
            primaryTypeIdentifier: "public.utf8-plain-text",
            representations: [ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8))],
            availableTypeIdentifiers: ["public.utf8-plain-text"],
            plainText: text
        )
        return ClipboardCapture(
            payload: payload,
            primaryType: .text,
            searchableText: text,
            source: ClipboardSource(appName: "Fixture Editor", bundleIdentifier: "fixture.editor")
        )
    }

    private func makeItem(text: String) -> ClipboardItem {
        ClipboardItem(
            capture: makeCapture(text: text),
            createdAt: Date()
        )
    }
}

private final class ControllerDatabaseFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryControllerTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("history.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
