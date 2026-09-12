import Foundation
import SQLite3
import XCTest
@testable import ClipboardCore

final class BlobPersistenceTests: XCTestCase {
    func testLargePayloadUsesBlobAndHydratesOnlyByIDAfterReopen() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await repository.open()

        let original = makeLargeItem(text: "synthetic external payload")
        let stored = try await repository.record(original)
        XCTAssertNotNil(stored.payloadBlobReference)
        let metadataRows = try await repository.history()
        XCTAssertNil(metadataRows.first?.payload)
        XCTAssertEqual(metadataRows.first?.payloadBlobReference, stored.payloadBlobReference)
        XCTAssertEqual(try blobFiles(in: fixture), 1)
        await repository.close()

        let reopened = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await reopened.open()
        let hydrated = try await reopened.item(id: stored.id)
        XCTAssertEqual(hydrated?.payload, original.payload)
        XCTAssertEqual(hydrated?.payloadBlobReference, stored.payloadBlobReference)
        await reopened.close()
    }

    func testVersionOneLargeInlinePayloadMigratesAndPreservesSearchAndPin() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let original = makeLargeItem(text: "synthetic legacy migration payload")
        try createVersionOneDatabase(with: original, at: fixture.databaseURL)

        let migrated = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await migrated.open()
        XCTAssertEqual(try userVersion(at: fixture.databaseURL), 2)
        let metadata = try await migrated.history(query: "legacy migration")
        XCTAssertEqual(metadata.map(\.id), [original.id])
        XCTAssertNil(metadata.first?.payload)
        XCTAssertNotNil(metadata.first?.payloadBlobReference)
        XCTAssertTrue(metadata.first?.isPinned == true)
        let hydrated = try await migrated.item(id: original.id)
        XCTAssertEqual(hydrated?.payload, original.payload)
        await migrated.close()
    }

    func testMetadataHistoryBoundsLargeSearchPreviewButSelectedItemKeepsFullText() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await repository.open()
        let longText = "synthetic\u{0000}" + String(repeating: "searchable text ", count: 100)
        let stored = try await repository.record(makeLargeItem(text: longText))

        let metadataRows = try await repository.history()
        XCTAssertEqual(metadataRows.count, 1)
        XCTAssertEqual(metadataRows[0].searchableText, String(longText.prefix(1_024)))
        let hydrated = try await repository.item(id: stored.id)
        XCTAssertEqual(hydrated?.searchableText, longText)
        await repository.close()
    }

    func testMissingCorruptAndUnsafeBlobAreItemLocalErrorsAndRowsRemainUsable() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await repository.open()

        let missing = try await repository.record(makeLargeItem(text: "synthetic missing blob"))
        guard let missingReference = missing.payloadBlobReference else {
            XCTFail("expected an external payload reference")
            return
        }
        try FileManager.default.removeItem(at: fixture.blobURL(for: missingReference))
        await XCTAssertThrowsErrorAsync(try await repository.item(id: missing.id)) { error in
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .payloadUnavailable)
        }
        let missingRows = try await repository.history()
        XCTAssertEqual(missingRows.count, 1)
        try await repository.delete(id: missing.id)
        let afterMissingDelete = try await repository.history()
        XCTAssertTrue(afterMissingDelete.isEmpty)

        let corrupt = try await repository.record(makeLargeItem(text: "synthetic corrupt blob"))
        guard let corruptReference = corrupt.payloadBlobReference else {
            XCTFail("expected an external payload reference")
            return
        }
        try Data("not JSON".utf8).write(to: fixture.blobURL(for: corruptReference))
        await XCTAssertThrowsErrorAsync(try await repository.item(id: corrupt.id)) { error in
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .payloadUnavailable)
        }

        try execute(
            "UPDATE clipboard_items SET payload_blob_reference = '../outside', payload_json = X'' WHERE id = '\(corrupt.id.uuidString)'",
            at: fixture.databaseURL
        )
        await XCTAssertThrowsErrorAsync(try await repository.item(id: corrupt.id)) { error in
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .payloadUnavailable)
        }
        let unsafeRows = try await repository.history()
        XCTAssertEqual(unsafeRows.count, 1)
        try await repository.delete(id: corrupt.id)
        let afterCorruptDelete = try await repository.history()
        XCTAssertTrue(afterCorruptDelete.isEmpty)
        await repository.close()
    }

    func testCorruptInlinePayloadIsItemLocalAndDeletable() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 1_000_000)
        try await repository.open()
        let stored = try await repository.record(makeLargeItem(text: "synthetic inline payload"))
        XCTAssertNil(stored.payloadBlobReference)

        let replacement = ClipboardPayload(
            primaryTypeIdentifier: "public.data",
            representations: [ClipboardRepresentation(typeIdentifier: "public.data", data: Data("synthetic replacement".utf8))],
            availableTypeIdentifiers: ["public.data"],
            plainText: "synthetic replacement"
        )
        try replaceInlinePayload(replacement, for: stored.id, at: fixture.databaseURL)

        await XCTAssertThrowsErrorAsync(try await repository.item(id: stored.id)) { error in
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .payloadUnavailable)
        }
        let rows = try await repository.history()
        XCTAssertEqual(rows.map(\.id), [stored.id])
        try await repository.delete(id: stored.id)
        let remaining = try await repository.history()
        XCTAssertTrue(remaining.isEmpty)
        await repository.close()
    }

    func testFailedRecordRollsBackAndRemovesStagedBlob() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await repository.open()
        try execute(
            "CREATE TRIGGER clipboard_items_blob_test_abort BEFORE INSERT ON clipboard_items BEGIN SELECT RAISE(ABORT, 'blob fixture'); END",
            at: fixture.databaseURL
        )

        await XCTAssertThrowsErrorAsync(try await repository.record(makeLargeItem(text: "synthetic failed blob transaction"))) { error in
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .operationFailed)
        }
        XCTAssertEqual(try blobFiles(in: fixture), 0)
        let rows = try await repository.history()
        XCTAssertTrue(rows.isEmpty)
        await repository.close()
    }

    func testCancelledRecordRollsBackAndRemovesStagedBlob() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await repository.open()
        let cancellation = CancellationBox()
        repository.recordBeforeCommitHook = {
            cancellation.request()
        }
        let item = makeLargeItem(text: "synthetic cancelled record")
        let task = Task {
            try await repository.record(item)
        }
        cancellation.install {
            task.cancel()
        }

        do {
            _ = try await task.value
            XCTFail("expected record cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try blobFiles(in: fixture), 0)
        let rows = try await repository.history()
        XCTAssertTrue(rows.isEmpty)
        await repository.close()
    }

    func testDeleteRetentionAndOrphanCleanupPreservePinnedBlob() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let policy = ClipboardHistoryRetention(maximumUnpinnedItems: 10, maximumUnpinnedAge: 10)
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, retention: policy, largePayloadThreshold: 64)
        try await repository.open()

        let pinned = try await repository.record(makeLargeItem(text: "synthetic pinned blob", at: 1), now: date(1))
        _ = try await repository.setPinned(true, for: pinned.id, now: date(1))
        let expired = try await repository.record(makeLargeItem(text: "synthetic expired blob", at: 2), now: date(2))
        guard let pinnedReference = pinned.payloadBlobReference, let expiredReference = expired.payloadBlobReference else {
            XCTFail("expected external references")
            return
        }

        let orphanReference = UUID().uuidString + ".blob"
        try Data("orphan".utf8).write(to: fixture.blobURL(for: orphanReference))
        let symlinkReference = UUID().uuidString + ".blob"
        let destination = fixture.directoryURL.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: fixture.blobURL(for: symlinkReference), withDestinationURL: destination)

        try await repository.enforceRetention(now: date(100))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.blobURL(for: pinnedReference).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.blobURL(for: expiredReference).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.blobURL(for: orphanReference).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.blobURL(for: symlinkReference).path))
        let retainedRows = try await repository.history()
        XCTAssertEqual(retainedRows.map(\.id), [pinned.id])

        try await repository.delete(id: pinned.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.blobURL(for: pinnedReference).path))
        await repository.close()
    }

    func testStartupRemovesOwnedStagingTempButLeavesUnknownFile() async throws {
        let fixture = try BlobDatabaseFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await repository.open()
        _ = try await repository.record(makeLargeItem(text: "synthetic temp cleanup"))
        await repository.close()

        let ownedTemp = "\(UUID().uuidString).blob.\(UUID().uuidString).tmp"
        let unknown = "unknown-private-file.tmp"
        try Data("owned temporary".utf8).write(to: fixture.blobURL(for: ownedTemp))
        try Data("unknown file".utf8).write(to: fixture.blobURL(for: unknown))

        let reopened = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 64)
        try await reopened.open()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.blobURL(for: ownedTemp).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.blobURL(for: unknown).path))
        await reopened.close()
    }

    private func makeLargeItem(text: String, at seconds: TimeInterval = Date().timeIntervalSinceReferenceDate) -> ClipboardItem {
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
            createdAt: date(seconds)
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}

private final class BlobDatabaseFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardBlobPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("history.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func blobURL(for reference: String) -> URL {
        directoryURL.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(reference)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func createVersionOneDatabase(with item: ClipboardItem, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let database else {
        throw NSError(domain: "BlobPersistenceTests", code: 10)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(
        database,
        """
        CREATE TABLE clipboard_items (
            id TEXT PRIMARY KEY NOT NULL,
            content_hash TEXT UNIQUE NOT NULL,
            primary_type TEXT NOT NULL,
            searchable_text TEXT,
            source_app_name TEXT,
            source_bundle_id TEXT,
            created_at REAL NOT NULL,
            last_used_at REAL NOT NULL,
            is_pinned INTEGER NOT NULL,
            byte_size INTEGER NOT NULL,
            payload_metadata_json BLOB NOT NULL,
            payload_blob_reference TEXT,
            payload_json BLOB NOT NULL,
            search_url TEXT,
            search_domain TEXT,
            search_metadata TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE clipboard_items_fts USING fts5(
            searchable_text, search_url, search_domain, source_app_name,
            source_bundle_id, search_metadata,
            content='clipboard_items', content_rowid='rowid'
        );
        CREATE TRIGGER clipboard_items_ai AFTER INSERT ON clipboard_items BEGIN
            INSERT INTO clipboard_items_fts(rowid, searchable_text, search_url, search_domain, source_app_name, source_bundle_id, search_metadata)
            VALUES (new.rowid, new.searchable_text, new.search_url, new.search_domain, new.source_app_name, new.source_bundle_id, new.search_metadata);
        END;
        CREATE TRIGGER clipboard_items_ad AFTER DELETE ON clipboard_items BEGIN
            INSERT INTO clipboard_items_fts(clipboard_items_fts, rowid, searchable_text, search_url, search_domain, source_app_name, source_bundle_id, search_metadata)
            VALUES ('delete', old.rowid, old.searchable_text, old.search_url, old.search_domain, old.source_app_name, old.source_bundle_id, old.search_metadata);
        END;
        CREATE TRIGGER clipboard_items_au AFTER UPDATE ON clipboard_items BEGIN
            INSERT INTO clipboard_items_fts(clipboard_items_fts, rowid, searchable_text, search_url, search_domain, source_app_name, source_bundle_id, search_metadata)
            VALUES ('delete', old.rowid, old.searchable_text, old.search_url, old.search_domain, old.source_app_name, old.source_bundle_id, old.search_metadata);
            INSERT INTO clipboard_items_fts(rowid, searchable_text, search_url, search_domain, source_app_name, source_bundle_id, search_metadata)
            VALUES (new.rowid, new.searchable_text, new.search_url, new.search_domain, new.source_app_name, new.source_bundle_id, new.search_metadata);
        END;
        PRAGMA user_version = 1;
        """,
        nil,
        nil,
        nil
    ) == SQLITE_OK else {
        throw NSError(domain: "BlobPersistenceTests", code: 11)
    }

    guard let payload = item.payload else {
        throw NSError(domain: "BlobPersistenceTests", code: 12)
    }
    let payloadData = try JSONEncoder().encode(payload)
    let metadataData = try JSONEncoder().encode(item.payloadMetadata)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        INSERT INTO clipboard_items (
            id, content_hash, primary_type, searchable_text, source_app_name,
            source_bundle_id, created_at, last_used_at, is_pinned, byte_size,
            payload_metadata_json, payload_blob_reference, payload_json, search_url,
            search_domain, search_metadata
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw NSError(domain: "BlobPersistenceTests", code: 13)
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    func bindText(_ value: String?, _ index: Int32) {
        if let value {
            _ = value.withCString {
                sqlite3_bind_text64(statement, index, $0, sqlite3_uint64(value.utf8.count), transient, UInt8(SQLITE_UTF8))
            }
        } else {
            _ = sqlite3_bind_null(statement, index)
        }
    }
    func bindData(_ value: Data, _ index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob64(statement, index, bytes.baseAddress, sqlite3_uint64(value.count), transient)
        }
    }
    bindText(item.id.uuidString, 1)
    bindText(item.contentHash, 2)
    bindText(item.primaryType.rawValue, 3)
    bindText(item.searchableText, 4)
    bindText(item.sourceAppName, 5)
    bindText(item.sourceBundleID, 6)
    _ = sqlite3_bind_double(statement, 7, item.createdAt.timeIntervalSinceReferenceDate)
    _ = sqlite3_bind_double(statement, 8, item.lastUsedAt.timeIntervalSinceReferenceDate)
    _ = sqlite3_bind_int64(statement, 9, 1)
    _ = sqlite3_bind_int64(statement, 10, sqlite3_int64(item.byteSize))
    bindData(metadataData, 11)
    _ = sqlite3_bind_null(statement, 12)
    bindData(payloadData, 13)
    _ = sqlite3_bind_null(statement, 14)
    _ = sqlite3_bind_null(statement, 15)
    bindText(item.payloadMetadata.availableTypeIdentifiers.joined(separator: " "), 16)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "BlobPersistenceTests", code: 14)
    }
}

private func execute(_ statement: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw NSError(domain: "BlobPersistenceTests", code: 1)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "BlobPersistenceTests", code: 2)
    }
}

private func replaceInlinePayload(_ payload: ClipboardPayload, for id: UUID, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let database else {
        throw NSError(domain: "BlobPersistenceTests", code: 20)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "UPDATE clipboard_items SET payload_json = ? WHERE id = ?",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw NSError(domain: "BlobPersistenceTests", code: 21)
    }
    defer { sqlite3_finalize(statement) }
    let data = try JSONEncoder().encode(payload)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let bindResult = data.withUnsafeBytes { bytes in
        sqlite3_bind_blob64(statement, 1, bytes.baseAddress, sqlite3_uint64(data.count), transient)
    }
    guard bindResult == SQLITE_OK else {
        throw NSError(domain: "BlobPersistenceTests", code: 22)
    }
    let idResult = id.uuidString.withCString {
        sqlite3_bind_text64(statement, 2, $0, sqlite3_uint64(id.uuidString.utf8.count), transient, UInt8(SQLITE_UTF8))
    }
    guard idResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "BlobPersistenceTests", code: 23)
    }
}

private func userVersion(at databaseURL: URL) throws -> Int32 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw NSError(domain: "BlobPersistenceTests", code: 3)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
        throw NSError(domain: "BlobPersistenceTests", code: 4)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "BlobPersistenceTests", code: 5)
    }
    return sqlite3_column_int(statement, 0)
}

private func blobFiles(in fixture: BlobDatabaseFixture) throws -> Int {
    guard FileManager.default.fileExists(atPath: fixture.directoryURL.appendingPathComponent("blobs").path) else {
        return 0
    }
    return try FileManager.default.contentsOfDirectory(at: fixture.directoryURL.appendingPathComponent("blobs"), includingPropertiesForKeys: nil).count
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

private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var requested = false

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if requested {
            lock.unlock()
            action()
            return
        }
        self.action = action
        lock.unlock()
    }

    func request() {
        lock.lock()
        requested = true
        let action = self.action
        lock.unlock()
        action?()
    }
}
