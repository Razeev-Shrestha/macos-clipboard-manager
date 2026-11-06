import Foundation
import XCTest
@testable import ClipboardCore

/// Verifies on-disk privacy guarantees: deleted text does not linger in the
/// database file, storage is owner-only, and it is kept out of backups.
final class StorageHardeningTests: XCTestCase {
    func testClearedTextIsNotRecoverableFromDatabaseFile() async throws {
        let fixture = try HardeningFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()

        for index in 0..<25 {
            _ = try await repository.record(makeItem(text: "synthetic zqxclearedmarker\(index) value"))
        }
        let kept = try await repository.record(makeItem(text: "synthetic pinned survivor"))
        _ = try await repository.setPinned(true, for: kept.id)

        try await repository.clear(keepingPinned: true)
        let remaining = try await repository.history()
        XCTAssertEqual(remaining.map(\.id), [kept.id])
        await repository.close()

        let bytes = try fixture.databaseBytes()
        XCTAssertNil(bytes.range(of: Data("zqxclearedmarker".utf8)), "cleared clipboard text remains in the database file")
        XCTAssertNotNil(bytes.range(of: Data("survivor".utf8)), "pinned text should remain")
    }

    func testDeletedItemTextIsNotRecoverableFromDatabaseFile() async throws {
        let fixture = try HardeningFixture()
        defer { fixture.remove() }
        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL)
        try await repository.open()

        let doomed = try await repository.record(makeItem(text: "synthetic zqxdeletedmarker token"))
        _ = try await repository.record(makeItem(text: "synthetic unrelated neighbour"))
        try await repository.delete(id: doomed.id)
        await repository.close()

        let bytes = try fixture.databaseBytes()
        XCTAssertNil(bytes.range(of: Data("zqxdeletedmarker".utf8)), "deleted clipboard text remains in the database file")
    }

    func testStorageDirectoryIsOwnerOnlyAndExcludedFromBackupAndSpotlight() async throws {
        let fixture = try HardeningFixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.storageURL.path)

        let repository = ClipboardHistoryRepository(databaseURL: fixture.databaseURL, largePayloadThreshold: 16)
        try await repository.open()
        _ = try await repository.record(makeItem(text: "synthetic payload large enough to become a blob file"))
        await repository.close()

        XCTAssertEqual(try permissions(of: fixture.storageURL), 0o700)
        XCTAssertEqual(try permissions(of: fixture.databaseURL), 0o600)
        let values = try fixture.storageURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.storageURL.appendingPathComponent(".metadata_never_index").path
        ))

        let blobRoot = fixture.storageURL.appendingPathComponent("blobs", isDirectory: true)
        XCTAssertEqual(try permissions(of: blobRoot), 0o700)
        let blobs = try FileManager.default.contentsOfDirectory(at: blobRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(blobs.count, 1)
        for blob in blobs {
            XCTAssertEqual(try permissions(of: blob), 0o600)
        }
    }

    func testSymbolicLinkStorageDirectoryIsRejected() async throws {
        let fixture = try HardeningFixture()
        defer { fixture.remove() }
        let elsewhere = fixture.rootURL.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let linked = fixture.rootURL.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)

        let repository = ClipboardHistoryRepository(
            databaseURL: linked.appendingPathComponent("history.sqlite", isDirectory: false)
        )
        do {
            try await repository.open()
            XCTFail("opening history through a symbolic-link directory should fail")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryRepositoryError, .openFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("history.sqlite").path))
    }

    private func makeItem(text: String) -> ClipboardItem {
        let payload = ClipboardPayload(
            primaryTypeIdentifier: "public.utf8-plain-text",
            representations: [ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8))],
            availableTypeIdentifiers: ["public.utf8-plain-text"],
            plainText: text
        )
        return ClipboardItem(
            capture: ClipboardCapture(payload: payload, primaryType: .text, searchableText: text),
            createdAt: Date()
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class HardeningFixture {
    let rootURL: URL
    let storageURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHardeningTests-\(UUID().uuidString)", isDirectory: true)
        storageURL = rootURL.appendingPathComponent("storage", isDirectory: true)
        databaseURL = storageURL.appendingPathComponent("history.sqlite", isDirectory: false)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }

    /// The database plus any journal left beside it.
    func databaseBytes() throws -> Data {
        var bytes = try Data(contentsOf: databaseURL)
        for suffix in ["-journal", "-wal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if let extra = try? Data(contentsOf: sidecar) {
                bytes.append(extra)
            }
        }
        return bytes
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
