import Foundation

public enum ClipboardHistoryUpdate: Equatable, Sendable {
    case inserted(ClipboardItem)
    case updated(ClipboardItem)

    public var item: ClipboardItem {
        switch self {
        case .inserted(let item), .updated(let item):
            return item
        }
    }
}

/// A bounded, value-semantic recent history.  It contains no persistence or AppKit
/// code, which keeps clipboard capture and future database work independently testable.
public struct InMemoryClipboardHistory: Sendable {
    private static let maxSearchableTextLength = 4_096

    public let maxItemCount: Int
    private var storedItems: [ClipboardItem]

    public init(maxItemCount: Int = 1_000, items: [ClipboardItem] = []) {
        self.maxItemCount = max(0, maxItemCount)
        self.storedItems = items.map(Self.metadataOnly)
        trimToLimit()
    }

    public var items: [ClipboardItem] {
        storedItems
    }

    public var count: Int {
        storedItems.count
    }

    @discardableResult
    public mutating func record(_ item: ClipboardItem) -> ClipboardHistoryUpdate {
        // The monitor cache is metadata-only. Payload hydration is owned by the
        // repository and is requested explicitly for copy or preview actions.
        let metadataItem = Self.metadataOnly(item)
        if let existingIndex = storedItems.firstIndex(where: { $0.contentHash == metadataItem.contentHash }) {
            let updatedItem = storedItems[existingIndex].updated(from: metadataItem)
            storedItems[existingIndex] = updatedItem
            sortByRecentUse()
            return .updated(updatedItem)
        }

        storedItems.append(metadataItem)
        sortByRecentUse()
        trimToLimit()
        return .inserted(metadataItem)
    }

    @discardableResult
    public mutating func record(
        _ capture: ClipboardCapture,
        at date: Date,
        id: UUID = UUID()
    ) -> ClipboardHistoryUpdate {
        record(ClipboardItem(id: id, capture: capture, createdAt: date, lastUsedAt: date))
    }

    @discardableResult
    public mutating func setPinned(_ pinned: Bool, for id: UUID) -> ClipboardItem? {
        guard let index = storedItems.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let updatedItem = storedItems[index].withPinning(pinned)
        storedItems[index] = updatedItem
        return updatedItem
    }

    @discardableResult
    mutating func markUsed(at date: Date, for id: UUID) -> ClipboardItem? {
        guard let index = storedItems.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let existing = storedItems[index]
        let updatedItem = ClipboardItem(
            id: existing.id,
            contentHash: existing.contentHash,
            primaryType: existing.primaryType,
            searchableText: existing.searchableText,
            sourceAppName: existing.sourceAppName,
            sourceBundleID: existing.sourceBundleID,
            createdAt: existing.createdAt,
            lastUsedAt: max(existing.lastUsedAt, date),
            isPinned: existing.isPinned,
            byteSize: existing.byteSize,
            payloadMetadata: existing.payloadMetadata,
            payloadBlobReference: existing.payloadBlobReference,
            payload: nil
        )
        storedItems[index] = updatedItem
        sortByRecentUse()
        return updatedItem
    }

    @discardableResult
    public mutating func remove(id: UUID) -> ClipboardItem? {
        guard let index = storedItems.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return storedItems.remove(at: index)
    }

    public mutating func clear(keepingPinned: Bool = false) {
        if keepingPinned {
            storedItems.removeAll(where: { !$0.isPinned })
        } else {
            storedItems.removeAll(keepingCapacity: true)
        }
    }

    /// Mirrors the repository's unpinned age and count retention rules while
    /// keeping pinned metadata available in the bounded monitor cache.
    mutating func applyRetention(_ retention: ClipboardHistoryRetention, now: Date) {
        let cutoff = now.timeIntervalSinceReferenceDate - retention.maximumUnpinnedAge
        storedItems.removeAll { item in
            !item.isPinned && item.lastUsedAt.timeIntervalSinceReferenceDate < cutoff
        }
        trimToLimit(min(maxItemCount, retention.maximumUnpinnedItems))
    }

    private mutating func sortByRecentUse() {
        storedItems.sort {
            if $0.lastUsedAt != $1.lastUsedAt {
                return $0.lastUsedAt > $1.lastUsedAt
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private mutating func trimToLimit() {
        trimToLimit(maxItemCount)
    }

    private mutating func trimToLimit(_ limit: Int) {
        sortByRecentUse()
        while storedItems.filter({ !$0.isPinned }).count > limit {
            guard let oldestUnpinnedIndex = storedItems.lastIndex(where: { !$0.isPinned }) else {
                break
            }
            storedItems.remove(at: oldestUnpinnedIndex)
        }
    }

    private static func metadataOnly(_ item: ClipboardItem) -> ClipboardItem {
        ClipboardItem(
            id: item.id,
            contentHash: item.contentHash,
            primaryType: item.primaryType,
            searchableText: item.searchableText.map { String($0.prefix(maxSearchableTextLength)) },
            sourceAppName: item.sourceAppName,
            sourceBundleID: item.sourceBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            byteSize: item.byteSize,
            payloadMetadata: item.payloadMetadata,
            payloadBlobReference: item.payloadBlobReference,
            payload: nil
        )
    }
}
