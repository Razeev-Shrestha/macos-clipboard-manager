import AppKit
import Combine

/// Main-actor state for the panel's current result set, keyboard selection, and
/// copy-only action. It deliberately contains no view layout or window ownership.
@MainActor
public final class ClipboardPanelViewModel: ObservableObject {
    @Published public private(set) var selectedID: UUID?
    @Published public private(set) var isPreviewVisible = false
    @Published public private(set) var searchFocusRequest = 0
    @Published public private(set) var selectionScrollRequest = 0
    @Published public private(set) var listOwnsKeyboardFocus = false
    @Published public private(set) var isCopying = false
    @Published public var shortcutStatus: String?
    @Published public private(set) var copyFailure: String?
    @Published public private(set) var visibleItemIDs: [UUID] = []

    public var onPreviewVisibilityChanged: ((Bool) -> Void)?
    public var onRequestClose: (() -> Void)?

    public let controller: ClipboardHistoryController
    private var selection = ClipboardSelectionState()
    private var copyTask: Task<Void, Never>?
    private var displayedQuery = ""
    private var displayedFilter: ClipboardHistoryFilter = .all

    public init(controller: ClipboardHistoryController) {
        self.controller = controller
    }

    public func prepareForOpening(itemIDs: [UUID]) {
        selection.resetForOpening(itemIDs: itemIDs)
        reconcileVisibleItems(with: itemIDs)
        synchronizeSelection()
        selectionScrollRequest &+= 1
        requestSearchFocus()
    }

    public func didClose() {
        copyTask?.cancel()
        copyTask = nil
        isCopying = false
        listOwnsKeyboardFocus = false
    }

    /// Accepts a controller publication whose query and filter were captured
    /// alongside its rows, avoiding inference from mutable search controls.
    public func acceptPublishedResults(_ results: ClipboardHistoryResults) {
        let resetsSelection = displayedQuery != results.query
            || displayedFilter != results.filter
        selection.updateItems(results.items.map(\.id), resetSelection: resetsSelection)
        displayedQuery = results.query
        displayedFilter = results.filter
        reconcileVisibleItems(with: results.items.map(\.id))
        synchronizeSelection()
    }

    public func updateVisibleItems(_ itemIDs: [UUID]) {
        let availableIDs = Set(selection.itemIDs)
        let callbackVisibleIDs = Set(itemIDs)
        let visible = selection.itemIDs.filter {
            availableIDs.contains($0) && callbackVisibleIDs.contains($0)
        }
        guard visible != visibleItemIDs else {
            return
        }
        visibleItemIDs = visible
    }

    public func visibleNumber(for itemID: UUID) -> Int? {
        visibleItemIDs.firstIndex(of: itemID).map { $0 + 1 }
    }

    public func select(_ id: UUID?) {
        selection.select(id)
        synchronizeSelection()
        requestSearchFocus()
    }

    public func requestSearchFocus() {
        listOwnsKeyboardFocus = false
        searchFocusRequest &+= 1
    }

    public func searchFocusChanged(_ isFocused: Bool) {
        if isFocused {
            listOwnsKeyboardFocus = false
        }
    }

    public func selectedItem(in items: [ClipboardItem]) -> ClipboardItem? {
        guard let selectedID else {
            return nil
        }
        return items.first(where: { $0.id == selectedID })
    }

    /// Whether the current selection belongs to the controller's last published
    /// result generation, rather than rows still visible during an async reload.
    public var hasCurrentResults: Bool {
        displayedQuery == controller.query
            && displayedFilter == controller.filter
    }

    public func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isCommand = modifiers == [.command]

        if isCommand, event.charactersIgnoringModifiers?.lowercased() == "k" {
            controller.query = ""
            requestSearchFocus()
            return true
        }

        if modifiers.isEmpty, event.keyCode == 53 { // Escape
            onRequestClose?()
            return true
        }

        if isCommand, let visibleNumber = visibleNumber(for: event) {
            guard hasCurrentResults,
                  visibleItemIDs.indices.contains(visibleNumber - 1)
            else {
                return true
            }
            let id = visibleItemIDs[visibleNumber - 1]
            selection.select(id)
            synchronizeSelection()
            copy(id: id)
            return true
        }

        if modifiers.isEmpty, (event.keyCode == 126 || event.keyCode == 125) { // Up / Down
            guard hasCurrentResults else {
                return true
            }
            selection.move(by: event.keyCode == 126 ? -1 : 1)
            listOwnsKeyboardFocus = true
            synchronizeSelection()
            return true
        }

        if (modifiers.isEmpty || isCommand),
           (event.keyCode == 36 || event.keyCode == 76),
           !event.isARepeat {
            guard hasCurrentResults, let selectedID else {
                return true
            }
            copy(id: selectedID)
            return true
        }

        if listOwnsKeyboardFocus,
           modifiers.isEmpty,
           (event.keyCode == 49 || event.keyCode == 124) { // Space / Right arrow
            selection.togglePreview()
            synchronizeSelection()
            return true
        }

        if !modifiers.contains(.command),
           !modifiers.contains(.control),
           let text = event.characters,
           text.rangeOfCharacter(from: .controlCharacters) == nil {
            listOwnsKeyboardFocus = false
        }

        return false
    }

    public func copySelected() {
        guard hasCurrentResults, let selectedID else {
            return
        }
        copy(id: selectedID)
    }

    private func copy(id: UUID) {
        guard !isCopying else {
            return
        }

        copyFailure = nil
        isCopying = true
        copyTask = Task { [weak self] in
            guard let self else {
                return
            }
            let didCopy = await controller.copyItem(id: id)
            guard !Task.isCancelled else {
                return
            }
            isCopying = false
            copyTask = nil
            if didCopy {
                onRequestClose?()
            } else {
                copyFailure = "Couldn’t copy this item. It may no longer be available."
            }
        }
    }

    private func synchronizeSelection() {
        let previousPreview = isPreviewVisible
        selectedID = selection.selectedID
        isPreviewVisible = selection.isPreviewVisible
        if previousPreview != isPreviewVisible {
            onPreviewVisibilityChanged?(isPreviewVisible)
        }
    }

    private func visibleNumber(for event: NSEvent) -> Int? {
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let digit = Int(characters),
              (1...9).contains(digit)
        else {
            return nil
        }
        return digit
    }

    /// Visibility callbacks need not run when a result publication retains the
    /// same IDs. Keep the last verified visible subset, but arrange it according
    /// to the newly published display order.
    private func reconcileVisibleItems(with itemIDs: [UUID]) {
        let previouslyVisible = Set(visibleItemIDs)
        visibleItemIDs = itemIDs.filter { previouslyVisible.contains($0) }
    }

}
