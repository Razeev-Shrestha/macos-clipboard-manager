import AppKit
import Foundation
import SQLite3
import XCTest
@testable import ClipboardCore

final class PersistenceTests: XCTestCase {
    @MainActor
    func testMetadataOnlyHistoryRowCannotMutatePasteboardDuringRestore() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()
        let stored = try await repository.record(makeItem(text: "synthetic unloaded restore", at: Date().timeIntervalSinceReferenceDate))
        let metadataRows = try await repository.history(limit: 1)
        XCTAssertEqual(metadataRows.map(\.id), [stored.id])
        guard let metadataOnlyRow = metadataRows.first else {
            XCTFail("expected metadata history row")
            return
        }
        XCTAssertNil(metadataOnlyRow.payload)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("synthetic existing private pasteboard", forType: .string))
        let existingChangeCount = pasteboard.changeCount
        let monitor = NSPasteboardMonitor(pasteboard: NSPasteboardBoundary(pasteboard: pasteboard))

        XCTAssertFalse(monitor.restore(metadataOnlyRow))
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic existing private pasteboard")
        XCTAssertEqual(pasteboard.changeCount, existingChangeCount)
        await repository.close()
    }

    func testOpenRecordAndReopenHydratesPayloadOnlyByID() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()

        let timestamp = Date()
        let original = makeItem(text: "synthetic\u{0000}persistence fixture", at: timestamp.timeIntervalSinceReferenceDate, source: "Editor")
        let stored = try await repository.record(original, now: timestamp)
        XCTAssertEqual(stored.payload?.plainText, "synthetic\u{0000}persistence fixture")
        await repository.close()

        let reopened = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await reopened.open()
        let rows = try await reopened.history()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].payload)
        XCTAssertEqual(rows[0].id, stored.id)
        let searchableRows = try await reopened.history(query: "persistence")
        XCTAssertEqual(searchableRows.map(\.id), [stored.id])

        let hydrated = try await reopened.item(id: stored.id)
        XCTAssertEqual(hydrated?.payload?.plainText, "synthetic\u{0000}persistence fixture")
        await reopened.close()
    }

    func testDuplicatePreservesIdentityPinCreationAndNewerUseTime() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()

        let first = try await repository.record(makeItem(text: "synthetic duplicate", at: 10, source: "Editor"), now: date(10))
        let pinned = try await repository.setPinned(true, for: first.id, now: date(11))
        XCTAssertTrue(pinned?.isPinned == true)

        let lateDuplicate = makeItem(text: "synthetic duplicate", at: 5, source: "Terminal")
        let updated = try await repository.record(lateDuplicate, now: date(12))
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.createdAt, first.createdAt)
        XCTAssertEqual(updated.lastUsedAt, first.lastUsedAt)
        XCTAssertTrue(updated.isPinned)
        XCTAssertEqual(updated.sourceAppName, "Editor")
        await repository.close()
    }

    func testRetentionUsesExactAgeBoundaryAndNeverPrunesPins() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let policy = ClipboardHistoryRetention(maximumUnpinnedItems: 2, maximumUnpinnedAge: 10)
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, retention: policy)
        try await repository.open()

        let pinned = try await repository.record(makeItem(text: "synthetic pinned", at: 1), now: date(1))
        _ = try await repository.setPinned(true, for: pinned.id, now: date(1))
        let atBoundary = try await repository.record(makeItem(text: "synthetic boundary", at: 10), now: date(20))
        _ = try await repository.record(makeItem(text: "synthetic old", at: 9), now: date(20))
        _ = try await repository.record(makeItem(text: "synthetic newest", at: 20), now: date(20))

        let rows = try await repository.history(limit: 10)
        XCTAssertTrue(rows.contains(where: { $0.id == pinned.id }))
        XCTAssertTrue(rows.contains(where: { $0.id == atBoundary.id }))
        XCTAssertTrue(rows.contains(where: { $0.searchableText == "synthetic newest" }))
        XCTAssertFalse(rows.contains(where: { $0.searchableText == "synthetic old" }))
        let prunedSearchRows = try await repository.history(query: "old", limit: 10)
        XCTAssertTrue(prunedSearchRows.isEmpty)
        await repository.close()
    }

    func testSearchFiltersAndLiteralPunctuationStayConsistentAfterUpdateAndDelete() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()

        let text = try await repository.record(makeItem(text: "synthetic [brackets] and \"quotes\"", at: 1, type: .text, source: "Editor"), now: date(1))
        let code = try await repository.record(makeItem(text: "synthetic swift fixture", at: 2, type: .code, source: "Terminal"), now: date(2))
        let link = try await repository.record(makeURLItem(url: "https://example.invalid/docs/synthetic", at: 3, source: "Browser"), now: date(3))
        let image = try await repository.record(makeItem(text: "synthetic image label", at: 4, type: .image, source: "Preview"), now: date(4))
        let file = try await repository.record(makeItem(text: "synthetic file label", at: 5, type: .files, source: "Finder"), now: date(5))
        _ = try await repository.setPinned(true, for: text.id, now: date(6))

        let literalRows = try await repository.history(query: "[brackets] \"quotes\"", limit: 10)
        let linkRows = try await repository.history(query: "example.invalid", filter: .links, limit: 10)
        let codeRows = try await repository.history(query: "Terminal", filter: .code, limit: 10)
        let bundleRows = try await repository.history(query: "fixture.browser", limit: 10)
        let pinnedRows = try await repository.history(filter: .pinned, limit: 10)
        let textRows = try await repository.history(filter: .text, limit: 10)
        let imageRows = try await repository.history(filter: .images, limit: 10)
        let fileRows = try await repository.history(filter: .files, limit: 10)
        let allRows = try await repository.history(limit: 10)
        XCTAssertEqual(literalRows.map(\.id), [text.id])
        XCTAssertEqual(linkRows.map(\.id), [link.id])
        XCTAssertEqual(codeRows.map(\.id), [code.id])
        XCTAssertEqual(bundleRows.map(\.id), [link.id])
        XCTAssertEqual(pinnedRows.map(\.id), [text.id])
        XCTAssertEqual(textRows.map(\.id), [text.id])
        XCTAssertEqual(imageRows.map(\.id), [image.id])
        XCTAssertEqual(fileRows.map(\.id), [file.id])
        XCTAssertEqual(allRows.map(\.id), [file.id, image.id, link.id, code.id, text.id])
        let punctuationRows = try await repository.history(query: "%*", limit: 10)
        XCTAssertTrue(punctuationRows.isEmpty)

        _ = try await repository.record(makeItem(text: "synthetic swift fixture", at: 5, type: .code, source: "Updated Terminal"), now: date(5))
        let updatedRows = try await repository.history(query: "Updated", limit: 10)
        XCTAssertEqual(updatedRows.map(\.id), [code.id])
        try await repository.delete(id: code.id)
        let deletedRows = try await repository.history(query: "swift", limit: 10)
        XCTAssertTrue(deletedRows.isEmpty)
        await repository.close()
    }

    func testOrderingIsStableAndUnpinEnforcesCountRetention() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(
            databaseURL: fixture.databaseURL,
            retention: ClipboardHistoryRetention(maximumUnpinnedItems: 1, maximumUnpinnedAge: 100)
        )
        try await repository.open()

        let first = try await repository.record(makeItem(text: "synthetic first", at: 9), now: date(10))
        _ = try await repository.setPinned(true, for: first.id, now: date(10))
        let second = try await repository.record(makeItem(text: "synthetic second", at: 10), now: date(10))
        let stableRows = try await repository.history(limit: 10)
        XCTAssertEqual(stableRows.map(\.id), [second.id, first.id])

        _ = try await repository.setPinned(false, for: first.id, now: date(10))
        let retained = try await repository.history(limit: 10)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained[0].id, second.id)
        await repository.close()
    }

    func testFutureSchemaFailsClosedAndFailedMigrationRollsBackVersion() async throws {
        let future = try DatabaseFixture()
        defer { future.remove() }
        try execute("PRAGMA user_version = 2", at: future.databaseURL)
        let futureRepository = ClipboardHistoryRepository(databaseURL: future.databaseURL)
        await XCTAssertThrowsErrorAsync(try await futureRepository.open()) { error in
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .unsupportedSchemaVersion)
        }

        let malformed = try DatabaseFixture()
        defer { malformed.remove() }
        try execute("CREATE TABLE clipboard_items (id TEXT PRIMARY KEY)", at: malformed.databaseURL)
        let malformedRepository = ClipboardHistoryRepository(databaseURL: malformed.databaseURL)
        await XCTAssertThrowsErrorAsync(try await malformedRepository.open()) { error in
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .migrationFailed)
        }
        XCTAssertEqual(try userVersion(at: malformed.databaseURL), 0)
    }

    func testCountRetentionKeepsTheTwoNewestSequentialCopies() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(
            databaseURL: fixture.databaseURL,
            retention: ClipboardHistoryRetention(maximumUnpinnedItems: 2, maximumUnpinnedAge: 100)
        )
        try await repository.open()
        _ = try await repository.record(makeItem(text: "synthetic oldest", at: 1), now: date(1))
        let middle = try await repository.record(makeItem(text: "synthetic middle", at: 2), now: date(2))
        let newest = try await repository.record(makeItem(text: "synthetic newest", at: 3), now: date(3))

        let retained = try await repository.history(limit: 10)
        XCTAssertEqual(retained.map(\.id), [newest.id, middle.id])
        let prunedRows = try await repository.history(query: "oldest", limit: 10)
        XCTAssertTrue(prunedRows.isEmpty)
        await repository.close()
    }

    func testEqualTimestampOrderingUsesCanonicalIDAsTieBreaker() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()
        let first = try await repository.record(makeItem(text: "synthetic equal first", at: 10), now: date(10))
        let second = try await repository.record(makeItem(text: "synthetic equal second", at: 10), now: date(10))

        let rows = try await repository.history(limit: 10)
        XCTAssertEqual(rows.map(\.id), [first.id, second.id].sorted { $0.uuidString < $1.uuidString })
        await repository.close()
    }

    func testFailedRecordTransactionLeavesExistingRowUntouched() async throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()
        let original = try await repository.record(makeItem(text: "synthetic transactional fixture", at: 1, source: "Original"), now: date(1))
        try execute(
            "CREATE TRIGGER clipboard_items_test_abort BEFORE UPDATE ON clipboard_items BEGIN SELECT RAISE(ABORT, 'fixture'); END",
            at: fixture.databaseURL
        )

        await XCTAssertThrowsErrorAsync(
            try await repository.record(makeItem(text: "synthetic transactional fixture", at: 2, source: "Replacement"), now: date(2))
        ) { error in
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .operationFailed)
        }

        let persisted = try await repository.item(id: original.id)
        XCTAssertEqual(persisted?.sourceAppName, "Original")
        XCTAssertEqual(persisted?.lastUsedAt, date(1))
        XCTAssertEqual(persisted?.payload?.plainText, "synthetic transactional fixture")
        await repository.close()
    }

    private func makeItem(text: String, at seconds: TimeInterval, type: ClipboardPrimaryType = .text, source: String? = nil) -> ClipboardItem {
        let payload = ClipboardPayload(
            primaryTypeIdentifier: "public.utf8-plain-text",
            representations: [ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8))],
            availableTypeIdentifiers: ["public.utf8-plain-text"],
            plainText: text
        )
        return ClipboardItem(
            capture: ClipboardCapture(payload: payload, primaryType: type, searchableText: text, source: ClipboardSource(appName: source, bundleIdentifier: source.map { "fixture.\($0.lowercased())" })),
            createdAt: date(seconds)
        )
    }

    private func makeURLItem(url: String, at seconds: TimeInterval, source: String) -> ClipboardItem {
        let parsedURL = URL(string: url)!
        let payload = ClipboardPayload(
            primaryTypeIdentifier: "public.url",
            representations: [ClipboardRepresentation(typeIdentifier: "public.url", data: Data(url.utf8))],
            availableTypeIdentifiers: ["public.url"],
            plainText: "displayed label",
            url: parsedURL
        )
        return ClipboardItem(
            capture: ClipboardCapture(payload: payload, primaryType: .url, searchableText: "displayed label", source: ClipboardSource(appName: source, bundleIdentifier: "fixture.browser")),
            createdAt: date(seconds)
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}

private final class DatabaseFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("history.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func execute(_ statement: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw NSError(domain: "PersistenceTests", code: 1)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "PersistenceTests", code: 2)
    }
}

private func userVersion(at databaseURL: URL) throws -> Int32 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw NSError(domain: "PersistenceTests", code: 3)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
        throw NSError(domain: "PersistenceTests", code: 4)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "PersistenceTests", code: 5)
    }
    return sqlite3_column_int(statement, 0)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        errorHandler(error)
    }
}
