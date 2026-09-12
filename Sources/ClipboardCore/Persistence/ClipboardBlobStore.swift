import Foundation

/// Filesystem storage for payload bytes that are too large to keep in SQLite.
/// References are generated filenames, never caller-controlled paths.
struct ClipboardBlobStore {
    static let defaultThreshold = 64 * 1024

    let rootURL: URL

    init(databaseURL: URL) {
        rootURL = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("blobs", isDirectory: true)
    }

    func stage(_ data: Data) throws -> String {
        try ensureRoot()
        let reference = "\(UUID().uuidString).blob"
        let destination = rootURL.appendingPathComponent(reference, isDirectory: false)
        let temporary = rootURL.appendingPathComponent("\(reference).\(UUID().uuidString).tmp", isDirectory: false)
        do {
            // The explicit unique temp name is the only staging path. Avoid
            // Data.write(.atomic), which may create an implementation-defined
            // sibling temp file that startup cleanup cannot identify.
            try data.write(to: temporary, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return reference
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ClipboardBlobStoreError.writeFailed
        }
    }

    func read(_ reference: String) throws -> Data {
        guard let url = validatedURL(for: reference), isRegularFile(url) else {
            throw ClipboardBlobStoreError.unavailable
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ClipboardBlobStoreError.unavailable
        }
    }

    func remove(_ reference: String) {
        guard let url = validatedURL(for: reference), isRegularFile(url) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    func cleanup(keeping references: Set<String>) throws {
        guard rootIsDirectory else {
            return
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for file in files {
            let reference = file.lastPathComponent
            if isOwnedTemporary(reference) {
                if isRegularFile(file) {
                    try FileManager.default.removeItem(at: file)
                }
                continue
            }
            guard isSafeReference(reference), !references.contains(reference), isRegularFile(file) else {
                continue
            }
            try FileManager.default.removeItem(at: file)
        }
    }

    private func ensureRoot() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: rootURL.path) {
            guard rootIsDirectory else {
                throw ClipboardBlobStoreError.writeFailed
            }
            return
        }
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        } catch {
            throw ClipboardBlobStoreError.writeFailed
        }
    }

    private var rootIsDirectory: Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return false
        }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: rootURL.path)) == nil else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: rootURL.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeDirectory
    }

    private func validatedURL(for reference: String) -> URL? {
        guard isSafeReference(reference), rootIsDirectory else {
            return nil
        }
        return rootURL.appendingPathComponent(reference, isDirectory: false)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            return false
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private func isSafeReference(_ reference: String) -> Bool {
        guard reference.hasSuffix(".blob") else {
            return false
        }
        let stem = String(reference.dropLast(".blob".count))
        return UUID(uuidString: stem) != nil
    }

    private func isOwnedTemporary(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[1] == "blob",
              components[3] == "tmp" else {
            return false
        }
        return UUID(uuidString: String(components[0])) != nil
            && UUID(uuidString: String(components[2])) != nil
    }
}

private enum ClipboardBlobStoreError: Error {
    case unavailable
    case writeFailed
}
