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
    public let maxItemCount: Int
    private var storedItems: [ClipboardItem]

    public init(maxItemCount: Int = 1_000, items: [ClipboardItem] = []) {
        self.maxItemCount = max(1, maxItemCount)
        self.storedItems = items
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
        if let existingIndex = storedItems.firstIndex(where: { $0.contentHash == item.contentHash }) {
            let updatedItem = storedItems[existingIndex].updated(from: item)
            storedItems[existingIndex] = updatedItem
            sortByRecentUse()
            return .updated(updatedItem)
        }

        storedItems.append(item)
        sortByRecentUse()
        trimToLimit()
        return .inserted(item)
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
        sortByRecentUse()
        while storedItems.filter({ !$0.isPinned }).count > maxItemCount {
            guard let oldestUnpinnedIndex = storedItems.lastIndex(where: { !$0.isPinned }) else {
                break
            }
            storedItems.remove(at: oldestUnpinnedIndex)
        }
    }
}
