import AppKit
import Foundation
import XCTest
@testable import ClipboardCore

@MainActor
private final class ControllerPasteboard: ClipboardPasteboard {
    var changeCount = 0
    var accessState: PasteboardAccessState = .allowed
    var snapshots: [Int: PasteboardReadResult] = [:]
    private(set) var excludedBundleIdentifiers: Set<String> = []

    func readSnapshotIfStable(expectedChangeCount: Int) -> PasteboardReadResult {
        guard let result = snapshots[expectedChangeCount] else {
            return .skipped(.empty)
        }
        if case .snapshot(let snapshot) = result,
           let bundleIdentifier = snapshot.capture.source?.bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier)
        {
            return .skipped(.privacyMarker)
        }
        return result
    }

    func write(payload: ClipboardPayload) -> PasteboardWriteResult {
        .failed
    }

    func setExcludedBundleIdentifiers(_ identifiers: Set<String>) {
        excludedBundleIdentifiers = identifiers
    }

    func record(_ capture: ClipboardCapture) {
        changeCount += 1
        snapshots[changeCount] = .snapshot(PasteboardSnapshot(changeCount: changeCount, capture: capture))
    }
}

@MainActor
final class ClipboardHistoryControllerTests: XCTestCase {
    func testCopyItemRestoresPersistedPayloadAndUpdatesOnlyUseTime() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()
        let createdAt = Date().addingTimeInterval(-60)
        let stored = try await repository.record(makeItem(text: "synthetic copy payload", createdAt: createdAt), now: createdAt)
        _ = try await repository.setPinned(true, for: stored.id)
        await repository.close()

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let controller = ClipboardHistoryController(
            pasteboard: NSPasteboardBoundary(pasteboard: pasteboard),
            databaseURL: fixture.databaseURL
        )
        await controller.start()

        let copiedSuccessfully = await controller.copyItem(id: stored.id)
        XCTAssertTrue(copiedSuccessfully)
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic copy payload")
        let receipt = await controller.copyItemWithReceipt(id: stored.id)
        XCTAssertNotNil(receipt)
        XCTAssertTrue(controller.isRestoreCurrent(receipt!))
        XCTAssertEqual(
            controller.pollNow(),
            .selfWriteSuppressed(changeCount: pasteboard.changeCount)
        )
        await controller.flush()

        let reopened = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await reopened.open()
        let copied = try await reopened.item(id: stored.id)
        XCTAssertEqual(copied?.id, stored.id)
        XCTAssertTrue(copied?.isPinned == true)
        XCTAssertEqual(copied?.createdAt, createdAt)
        XCTAssertEqual(copied?.sourceAppName, "Fixture Editor")
        XCTAssertGreaterThan(copied?.lastUsedAt ?? .distantPast, createdAt)
        let rows = try await reopened.history()
        XCTAssertEqual(rows.count, 1)
        await reopened.close()
        await controller.shutdown()
    }

    func testMissingFailedAndCancelledCopyLeavePrivatePasteboardUntouched() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()
        let stored = try await repository.record(makeItem(text: "synthetic valid cancelled copy"))

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("synthetic existing private board", forType: .string)
        let controller = ClipboardHistoryController(
            pasteboard: NSPasteboardBoundary(pasteboard: pasteboard),
            repository: repository
        )
        await controller.start()

        let missingCopy = await controller.copyItem(id: UUID())
        XCTAssertFalse(missingCopy)
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic existing private board")

        let changeCountBeforeCancellation = pasteboard.changeCount
        let cancelledCopy = Task { @MainActor in
            await controller.copyItem(id: stored.id)
        }
        cancelledCopy.cancel()
        let cancelledResult = await cancelledCopy.value
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic existing private board")
        XCTAssertEqual(pasteboard.changeCount, changeCountBeforeCancellation)

        await repository.close()
        let failedCopy = await controller.copyItem(id: stored.id)
        XCTAssertFalse(failedCopy)
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic existing private board")
        XCTAssertEqual(pasteboard.changeCount, changeCountBeforeCancellation)
        await controller.shutdown()
    }

    func testSuccessfulCopyQueuesRecencyUpdateForShutdown() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()
        let createdAt = Date().addingTimeInterval(-60)
        let stored = try await repository.record(makeItem(text: "synthetic shutdown copy", createdAt: createdAt), now: createdAt)
        await repository.close()

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let controller = ClipboardHistoryController(
            pasteboard: NSPasteboardBoundary(pasteboard: pasteboard),
            databaseURL: fixture.databaseURL
        )
        await controller.start()
        let copiedSuccessfully = await controller.copyItem(id: stored.id)
        XCTAssertTrue(copiedSuccessfully)
        await controller.shutdown()

        let reopened = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await reopened.open()
        let copied = try await reopened.item(id: stored.id)
        XCTAssertGreaterThan(copied?.lastUsedAt ?? .distantPast, createdAt)
        await reopened.close()
    }
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

    func testClearWaitsForAcceptedCaptureAndPreventsLateResurrection() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, databaseURL: fixture.databaseURL)
        await controller.start()

        pasteboard.record(makeCapture(text: "synthetic queued before clear"))
        guard case .captured = controller.pollNow() else {
            XCTFail("expected an accepted capture")
            return
        }

        let didClear = await controller.clearHistory()
        XCTAssertTrue(didClear)
        await controller.flush()
        XCTAssertTrue(controller.items.isEmpty)

        let reopened = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await reopened.open()
        let rows = try await reopened.history()
        XCTAssertTrue(rows.isEmpty)
        await reopened.close()
        await controller.shutdown()
    }

#if DEBUG
    func testPolicyChangeCancelsCaptureAtCommitGateWithoutFailingStorage() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let pasteboard = ControllerPasteboard()
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        let controller = ClipboardHistoryController(pasteboard: pasteboard, repository: repository)
        await controller.start()

        let recordReachedCommitGate = AsyncStream<Void>.makeStream()
        let releaseCommitGate = DispatchSemaphore(value: 0)
        repository.recordBeforeCommitHook = {
            recordReachedCommitGate.continuation.yield(())
            releaseCommitGate.wait()
        }

        pasteboard.record(makeCapture(text: "synthetic canceled delayed record"))
        guard case .captured = controller.pollNow() else {
            XCTFail("expected an accepted capture")
            await controller.shutdown()
            return
        }

        var commitGateIterator = recordReachedCommitGate.stream.makeAsyncIterator()
        _ = await commitGateIterator.next()

        controller.setRecordingPaused(true)
        releaseCommitGate.signal()
        await controller.flush()

        XCTAssertEqual(controller.storageState, .ready)
        XCTAssertTrue(controller.items.isEmpty)
        let rows = try await repository.history()
        XCTAssertTrue(rows.isEmpty)
        await controller.shutdown()
    }
#endif

    func testPinDeleteAndClearActionsUpdateDurableRows() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, databaseURL: fixture.databaseURL)
        await controller.start()

        pasteboard.record(makeCapture(text: "synthetic pinned row"))
        _ = controller.pollNow()
        await controller.flush()
        guard let id = controller.items.first?.id else {
            XCTFail("expected a persisted row")
            return
        }

        let didPin = await controller.setPinned(true, for: id)
        XCTAssertTrue(didPin)
        await controller.flush()
        XCTAssertTrue(controller.items.first?.isPinned == true)
        let didDelete = await controller.deleteItem(id: id)
        XCTAssertTrue(didDelete)
        await controller.flush()
        XCTAssertTrue(controller.items.isEmpty)

        pasteboard.record(makeCapture(text: "synthetic clear row"))
        _ = controller.pollNow()
        await controller.flush()
        XCTAssertFalse(controller.items.isEmpty)
        let didClear = await controller.clearHistory()
        XCTAssertTrue(didClear)
        await controller.flush()
        XCTAssertTrue(controller.items.isEmpty)
        await controller.shutdown()
    }

    func testRecopyUpdatesCachedRecencyBeforeLaterCountAndAgePruning() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let policy = ClipboardHistoryRetention(maximumUnpinnedItems: 2, maximumUnpinnedAge: 10)
        var clock = Date(timeIntervalSinceReferenceDate: 100)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, retention: policy)
        let controller = ClipboardHistoryController(
            pasteboard: boundary,
            repository: repository,
            retention: policy,
            now: { clock }
        )
        await controller.start()

        func writeText(_ text: String) {
            _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
            XCTAssertTrue(pasteboard.setString(text, forType: .string))
        }

        writeText("synthetic recopy A")
        guard case .captured = controller.pollNow() else {
            XCTFail("expected first captured row")
            await controller.shutdown()
            return
        }
        await controller.flush()
        guard let firstID = controller.items.first?.id else {
            XCTFail("expected first row")
            await controller.shutdown()
            return
        }

        clock = Date(timeIntervalSinceReferenceDate: 109)
        writeText("synthetic recopy B")
        guard case .captured = controller.pollNow() else {
            XCTFail("expected second captured row")
            await controller.shutdown()
            return
        }
        await controller.flush()

        clock = Date(timeIntervalSinceReferenceDate: 111)
        let receipt = await controller.copyItemWithReceipt(id: firstID)
        XCTAssertNotNil(receipt)
        guard let durableRecopied = try await repository.item(id: firstID) else {
            XCTFail("expected recopied durable row")
            await controller.shutdown()
            return
        }
        XCTAssertEqual(durableRecopied.lastUsedAt, clock)

        clock = Date(timeIntervalSinceReferenceDate: 112)
        writeText("synthetic recopy C")
        guard case .captured = controller.pollNow() else {
            XCTFail("expected third captured row")
            await controller.shutdown()
            return
        }
        await controller.flush()

        let durableRows = try await repository.history()
        XCTAssertEqual(durableRows.map(\.searchableText), ["synthetic recopy C", "synthetic recopy A"])
        XCTAssertFalse(durableRows.contains(where: { $0.searchableText == "synthetic recopy B" }))

        XCTAssertEqual(
            controller.transientCacheItems.map(\.searchableText),
            ["synthetic recopy C", "synthetic recopy A"]
        )
        guard let cachedRecopied = controller.transientCacheItems.first(where: { $0.id == firstID }) else {
            XCTFail("expected recopied metadata in cache")
            await controller.shutdown()
            return
        }
        XCTAssertEqual(cachedRecopied.lastUsedAt, durableRecopied.lastUsedAt)
        XCTAssertEqual(cachedRecopied.isPinned, durableRecopied.isPinned)
        await controller.shutdown()
    }

    func testMissingPayloadKeepsControllerReadyAndRowDeletable() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let repository = ClipboardHistoryRepository(
            databaseURL: fixture.databaseURL,
            largePayloadThreshold: 64
        )
        try await repository.open()
        let stored = try await repository.record(makeLargeItem(text: "synthetic missing selected payload"))
        guard let reference = stored.payloadBlobReference else {
            XCTFail("expected a blob-backed payload")
            return
        }
        try FileManager.default.removeItem(at: fixture.directoryURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(reference))

        let controller = ClipboardHistoryController(
            pasteboard: ControllerPasteboard(),
            repository: repository
        )
        await controller.start()
        let copied = await controller.copyItem(id: stored.id)
        XCTAssertFalse(copied)
        XCTAssertEqual(controller.storageState, .ready)

        let deleted = await controller.deleteItem(id: stored.id)
        XCTAssertTrue(deleted)
        await controller.flush()
        XCTAssertTrue(controller.items.isEmpty)
        await controller.shutdown()
    }

    func testMultiItemEnrichmentKeepsDerivedRTFTextAlongsideExistingSearchText() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let firstText = "synthetic first item"
        let rtf = Data("{\\rtf1\\ansi synthetic rich item}".utf8)
        let first = ClipboardPayloadItem(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            representations: [
                ClipboardRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data(firstText.utf8)
                )
            ],
            availableTypeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
            plainText: firstText
        )
        let second = ClipboardPayloadItem(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue,
            representations: [
                ClipboardRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue,
                    data: rtf
                )
            ],
            availableTypeIdentifiers: [NSPasteboard.PasteboardType.rtf.rawValue]
        )
        let payload = ClipboardPayload(
            primaryTypeIdentifier: first.primaryTypeIdentifier,
            representations: first.representations,
            availableTypeIdentifiers: first.availableTypeIdentifiers,
            plainText: first.plainText,
            items: [first, second]
        )
        let capture = ClipboardCapture(
            payload: payload,
            primaryType: .text,
            searchableText: firstText
        )
        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, databaseURL: fixture.databaseURL)
        await controller.start()

        pasteboard.record(capture)
        _ = controller.pollNow()
        await controller.flush()

        guard let searchableText = controller.items.first?.searchableText else {
            XCTFail("expected an enriched searchable row")
            return
        }
        XCTAssertTrue(searchableText.contains(firstText))
        XCTAssertTrue(searchableText.contains("synthetic rich item"))
        await controller.shutdown()
    }

    func testRetentionReductionDropsRemovedUnpinnedMetadataFromMonitorCache() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(pasteboard: pasteboard, databaseURL: fixture.databaseURL)
        await controller.start()

        pasteboard.record(makeCapture(text: "synthetic pinned cache text"))
        _ = controller.pollNow()
        await controller.flush()
        guard let pinnedID = controller.items.first?.id else {
            XCTFail("expected a pinned candidate")
            return
        }
        let didPin = await controller.setPinned(true, for: pinnedID)
        XCTAssertTrue(didPin)
        await controller.flush()

        pasteboard.record(makeCapture(text: "synthetic expired cache text"))
        _ = controller.pollNow()
        await controller.flush()
        XCTAssertTrue(controller.transientCacheItems.contains(where: {
            $0.searchableText == "synthetic expired cache text"
        }))

        let reduced = await controller.updateRetention(
            ClipboardRetentionSettings(maximumUnpinnedItems: 0, maximumUnpinnedAge: 30 * 24 * 60 * 60),
            now: Date()
        )
        XCTAssertTrue(reduced)
        await controller.flush()

        XCTAssertEqual(controller.items.map(\.id), [pinnedID])
        XCTAssertTrue(controller.transientCacheItems.contains(where: { $0.id == pinnedID }))
        XCTAssertFalse(controller.transientCacheItems.contains(where: {
            $0.searchableText == "synthetic expired cache text"
        }))
        await controller.shutdown()
    }

    func testUnpinningAnAgedPinnedRowRemovesDurableAndTransientMetadata() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let policy = ClipboardHistoryRetention(maximumUnpinnedItems: 100, maximumUnpinnedAge: 10)
        var clock = Date(timeIntervalSinceReferenceDate: 100)
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, retention: policy)
        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(
            pasteboard: pasteboard,
            repository: repository,
            retention: policy,
            now: { clock }
        )
        await controller.start()

        pasteboard.record(makeCapture(text: "synthetic aged pinned row"))
        _ = controller.pollNow()
        await controller.flush()
        guard let itemID = controller.items.first?.id else {
            XCTFail("expected a captured row")
            return
        }
        let didPin = await controller.setPinned(true, for: itemID)
        XCTAssertTrue(didPin)

        clock = Date(timeIntervalSinceReferenceDate: 111)
        _ = await controller.setPinned(false, for: itemID)
        await controller.flush()

        let rows = try await repository.history()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(controller.transientCacheItems.contains(where: { $0.id == itemID }))
        await controller.shutdown()
    }

    func testCaptureAgeRetentionRemovesEvictedMetadataFromMonitorCache() async throws {
        let fixture = try ControllerDatabaseFixture()
        defer { fixture.remove() }

        let policy = ClipboardHistoryRetention(maximumUnpinnedItems: 100, maximumUnpinnedAge: 10)
        var clock = Date(timeIntervalSinceReferenceDate: 100)
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, retention: policy)
        let pasteboard = ControllerPasteboard()
        let controller = ClipboardHistoryController(
            pasteboard: pasteboard,
            repository: repository,
            retention: policy,
            now: { clock }
        )
        await controller.start()

        pasteboard.record(makeCapture(text: "synthetic capture age expired"))
        _ = controller.pollNow()
        await controller.flush()
        guard let oldID = controller.items.first?.id else {
            XCTFail("expected an initial captured row")
            return
        }

        clock = Date(timeIntervalSinceReferenceDate: 111)
        pasteboard.record(makeCapture(text: "synthetic capture age current"))
        _ = controller.pollNow()
        await controller.flush()

        let rows = try await repository.history()
        XCTAssertEqual(rows.map(\.searchableText), ["synthetic capture age current"])
        XCTAssertFalse(controller.transientCacheItems.contains(where: { $0.id == oldID }))
        XCTAssertEqual(
            controller.transientCacheItems.map(\.searchableText),
            ["synthetic capture age current"]
        )
        await controller.shutdown()
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
        XCTAssertEqual(controller.results.query, "synthetic fresh")
        XCTAssertEqual(controller.results.filter, .all)
        controller.filter = .text
        await controller.flush()
        XCTAssertEqual(controller.items.map(\.searchableText), ["synthetic fresh row"])
        XCTAssertEqual(controller.results.query, "synthetic fresh")
        XCTAssertEqual(controller.results.filter, .text)
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

    private func makeItem(text: String, createdAt: Date = Date()) -> ClipboardItem {
        ClipboardItem(
            capture: makeCapture(text: text),
            createdAt: createdAt
        )
    }

    private func makeLargeItem(text: String) -> ClipboardItem {
        var data = Data(text.utf8)
        data.append(Data(repeating: 0x41, count: 128))
        let payload = ClipboardPayload(
            primaryTypeIdentifier: "public.data",
            representations: [ClipboardRepresentation(typeIdentifier: "public.data", data: data)],
            availableTypeIdentifiers: ["public.data"],
            plainText: text
        )
        return ClipboardItem(
            capture: ClipboardCapture(payload: payload, primaryType: .other, searchableText: text),
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
