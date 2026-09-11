import Foundation

/// The small set of content classes understood by Gate A.
public enum ClipboardPrimaryType: String, CaseIterable, Codable, Hashable, Sendable {
    case text
    case code
    case url
    case richText
    case image
    case files
    case other
}

/// The application that supplied a clipboard item, when that information is available.
public struct ClipboardSource: Codable, Equatable, Hashable, Sendable {
    public let appName: String?
    public let bundleIdentifier: String?

    public init(appName: String? = nil, bundleIdentifier: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}

/// One pasteboard representation.  Gate A reads text and URL data, while this value
/// can carry additional representations when later capture phases are added.
public struct ClipboardRepresentation: Codable, Equatable, Hashable, Sendable {
    public let typeIdentifier: String
    public let data: Data

    public init(typeIdentifier: String, data: Data) {
        self.typeIdentifier = typeIdentifier
        self.data = data
    }
}

/// The restorable payload and the representation metadata observed on the pasteboard.
/// `availableTypeIdentifiers` intentionally preserves types that are not read yet so a
/// later rich-data phase can extend capture without changing the history model.
public struct ClipboardPayload: Codable, Equatable, Hashable, Sendable {
    public let primaryTypeIdentifier: String
    public let representations: [ClipboardRepresentation]
    public let availableTypeIdentifiers: [String]
    public let plainText: String?
    public let url: URL?

    public init(
        primaryTypeIdentifier: String,
        representations: [ClipboardRepresentation],
        availableTypeIdentifiers: [String] = [],
        plainText: String? = nil,
        url: URL? = nil
    ) {
        self.primaryTypeIdentifier = primaryTypeIdentifier
        self.representations = representations
        self.availableTypeIdentifiers = availableTypeIdentifiers
        self.plainText = plainText
        self.url = url
    }

    public var byteSize: Int {
        representations.reduce(into: 0) { total, representation in
            total += representation.data.count
        }
    }

    /// The preferred representation, when available.  The hasher includes all
    /// captured representation bytes so a restored multi-representation payload has
    /// one complete identity.
    public var identityRepresentation: ClipboardRepresentation? {
        if let preferred = representations.first(where: { $0.typeIdentifier == primaryTypeIdentifier }) {
            return preferred
        }
        return representations.first
    }
}

/// A captured pasteboard item before it receives history identity and timestamps.
public struct ClipboardCapture: Codable, Equatable, Hashable, Sendable {
    public let payload: ClipboardPayload
    public let primaryType: ClipboardPrimaryType
    public let searchableText: String?
    public let source: ClipboardSource?

    public init(
        payload: ClipboardPayload,
        primaryType: ClipboardPrimaryType,
        searchableText: String? = nil,
        source: ClipboardSource? = nil
    ) {
        self.payload = payload
        self.primaryType = primaryType
        self.searchableText = searchableText ?? payload.plainText ?? payload.url?.absoluteString
        self.source = source
    }
}

/// Metadata kept beside the payload so persistence can later move large data to a blob.
public struct ClipboardPayloadMetadata: Codable, Equatable, Hashable, Sendable {
    public let primaryTypeIdentifier: String
    public let availableTypeIdentifiers: [String]

    public init(primaryTypeIdentifier: String, availableTypeIdentifiers: [String]) {
        self.primaryTypeIdentifier = primaryTypeIdentifier
        self.availableTypeIdentifiers = availableTypeIdentifiers
    }
}

/// An immutable history row.  Updates return a new value and preserve the identity,
/// pin state, and creation time of an existing duplicate.
public struct ClipboardItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let contentHash: String
    public let primaryType: ClipboardPrimaryType
    public let searchableText: String?
    public let sourceAppName: String?
    public let sourceBundleID: String?
    public let createdAt: Date
    public let lastUsedAt: Date
    public let isPinned: Bool
    public let byteSize: Int
    public let payloadMetadata: ClipboardPayloadMetadata
    public let payloadBlobReference: String?
    public let payload: ClipboardPayload

    public var sourceBundleIdentifier: String? {
        sourceBundleID
    }

    public init(
        id: UUID = UUID(),
        capture: ClipboardCapture,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        isPinned: Bool = false,
        payloadBlobReference: String? = nil
    ) {
        self.id = id
        self.contentHash = ClipboardHasher.identity(for: capture.payload)
        self.primaryType = capture.primaryType
        self.searchableText = capture.searchableText
        self.sourceAppName = capture.source?.appName
        self.sourceBundleID = capture.source?.bundleIdentifier
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.isPinned = isPinned
        self.byteSize = capture.payload.byteSize
        self.payloadMetadata = ClipboardPayloadMetadata(
            primaryTypeIdentifier: capture.payload.primaryTypeIdentifier,
            availableTypeIdentifiers: capture.payload.availableTypeIdentifiers
        )
        self.payloadBlobReference = payloadBlobReference
        self.payload = capture.payload
    }

    internal init(
        id: UUID,
        contentHash: String,
        primaryType: ClipboardPrimaryType,
        searchableText: String?,
        sourceAppName: String?,
        sourceBundleID: String?,
        createdAt: Date,
        lastUsedAt: Date,
        isPinned: Bool,
        byteSize: Int,
        payloadMetadata: ClipboardPayloadMetadata,
        payloadBlobReference: String?,
        payload: ClipboardPayload
    ) {
        self.id = id
        self.contentHash = contentHash
        self.primaryType = primaryType
        self.searchableText = searchableText
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.byteSize = byteSize
        self.payloadMetadata = payloadMetadata
        self.payloadBlobReference = payloadBlobReference
        self.payload = payload
    }

    internal func updated(from incoming: ClipboardItem) -> ClipboardItem {
        ClipboardItem(
            id: id,
            contentHash: contentHash,
            primaryType: incoming.primaryType,
            searchableText: incoming.searchableText,
            sourceAppName: incoming.sourceAppName,
            sourceBundleID: incoming.sourceBundleID,
            createdAt: createdAt,
            lastUsedAt: max(lastUsedAt, incoming.lastUsedAt),
            isPinned: isPinned,
            byteSize: incoming.byteSize,
            payloadMetadata: incoming.payloadMetadata,
            payloadBlobReference: incoming.payloadBlobReference ?? payloadBlobReference,
            payload: incoming.payload
        )
    }

    public func withPinning(_ pinned: Bool) -> ClipboardItem {
        ClipboardItem(
            id: id,
            contentHash: contentHash,
            primaryType: primaryType,
            searchableText: searchableText,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            isPinned: pinned,
            byteSize: byteSize,
            payloadMetadata: payloadMetadata,
            payloadBlobReference: payloadBlobReference,
            payload: payload
        )
    }
}
