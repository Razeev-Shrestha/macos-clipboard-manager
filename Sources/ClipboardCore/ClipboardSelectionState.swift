import Foundation

public struct ClipboardSelectionState: Equatable, Sendable {
    public private(set) var selectedID: UUID?
    public private(set) var itemIDs: [UUID]
    public private(set) var isPreviewVisible: Bool

    public init() {
        selectedID = nil
        itemIDs = []
        isPreviewVisible = false
    }

    public mutating func updateItems(_ ids: [UUID], resetSelection: Bool = false) {
        let previousSelectionIndex = selectedID.flatMap { itemIDs.firstIndex(of: $0) }
        itemIDs = ids

        if resetSelection {
            selectedID = ids.first
        } else if let selectedID, ids.contains(selectedID) {
            self.selectedID = selectedID
        } else if let previousSelectionIndex, !ids.isEmpty {
            selectedID = ids[min(previousSelectionIndex, ids.count - 1)]
        } else {
            selectedID = ids.first
        }
    }

    public mutating func select(_ id: UUID?) {
        guard let id else {
            selectedID = nil
            return
        }
        guard itemIDs.contains(id) else {
            return
        }
        selectedID = id
    }

    public mutating func move(by offset: Int) {
        guard !itemIDs.isEmpty else {
            selectedID = nil
            return
        }

        guard let selected = selectedID, let currentIndex = itemIDs.firstIndex(of: selected) else {
            selectedID = offset < 0 ? itemIDs.last : itemIDs.first
            return
        }

        let destination = min(max(currentIndex + offset, 0), itemIDs.count - 1)
        selectedID = itemIDs[destination]
    }

    @discardableResult
    public mutating func selectVisibleItem(number: Int) -> UUID? {
        guard (1 ... 9).contains(number), itemIDs.indices.contains(number - 1) else {
            return nil
        }
        let id = itemIDs[number - 1]
        selectedID = id
        return id
    }

    public mutating func togglePreview() {
        isPreviewVisible.toggle()
    }

    public mutating func resetForOpening(itemIDs: [UUID]) {
        self.itemIDs = itemIDs
        selectedID = itemIDs.first
        isPreviewVisible = false
    }
}
