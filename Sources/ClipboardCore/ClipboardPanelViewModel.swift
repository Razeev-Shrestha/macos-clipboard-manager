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
    @Published public private(set) var shortcutHint = "⌘⇧V"
    @Published public private(set) var copyFailure: String?
    @Published public private(set) var pasteStatus: String?
    @Published public private(set) var historyMutationFailure: String?
    @Published public private(set) var pendingDeletionID: UUID?
    @Published public private(set) var canAutomaticallyPaste = false
    @Published public private(set) var visibleItemIDs: [UUID] = []
    @Published public private(set) var previewItem: ClipboardItem?
    @Published public private(set) var isLoadingPreview = false
    @Published public private(set) var previewError: String?

    public var onPreviewVisibilityChanged: ((Bool) -> Void)?
    public var onRequestClose: (() -> Void)?
    public var onPasteRequested: ((UUID, ClipboardPasteIntent) -> Void)?
    public var onRequestAccessibilityAccess: (() -> Void)?
    public var onPinRequested: ((UUID) -> Void)?
    public var onDeleteRequested: ((UUID) -> Void)?
    public var onClearHistoryRequested: ((Bool) -> Void)?

    public let controller: ClipboardHistoryController
    private var selection = ClipboardSelectionState()
    private var displayedQuery = ""
    private var displayedFilter: ClipboardHistoryFilter = .all
    private var previewLoadTask: Task<Void, Never>?
    private var previewLoadGeneration = 0
    private var isPanelPresented = false
    private var hasChromeControlFocus = false

    public init(controller: ClipboardHistoryController) {
        self.controller = controller
    }

    public func prepareForOpening(itemIDs: [UUID]) {
        isPanelPresented = true
        hasChromeControlFocus = false
        selection.resetForOpening(itemIDs: itemIDs)
        reconcileVisibleItems(with: itemIDs)
        synchronizeSelection()
        selectionScrollRequest &+= 1
        requestSearchFocus()
    }

    public func didClose() {
        isPanelPresented = false
        hasChromeControlFocus = false
        listOwnsKeyboardFocus = false
        cancelPreviewLoad()
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
        listOwnsKeyboardFocus = true
        synchronizeSelection()
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

    public func updateAutomaticPasteAvailability(_ available: Bool) {
        canAutomaticallyPaste = available
    }

    public func requestAccessibilityAccess() {
        onRequestAccessibilityAccess?()
    }

    public func updateShortcutHint(_ hint: String) {
        shortcutHint = hint
    }

    public func receivePasteOutcome(_ outcome: ClipboardPasteOutcome) {
        isCopying = false
        copyFailure = nil

        switch outcome {
        case .pasteRequested:
            pasteStatus = nil
        case let .copiedOnly(reason):
            pasteStatus = copyOnlyMessage(for: reason)
        case .copyFailed:
            pasteStatus = nil
            copyFailure = "Couldn’t copy this item. It may no longer be available."
        case .cancelled:
            pasteStatus = nil
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

    public func chromeControlFocusChanged(_ isFocused: Bool) {
        hasChromeControlFocus = isFocused
        if isFocused { listOwnsKeyboardFocus = false }
    }

    public func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isCommand = modifiers == [.command]

        // Let a focused native control consume activation/navigation keys.
        // Explicit row selection can reclaim list actions even if AppKit keeps
        // the former control as first responder. Command shortcuts remain global.
        if hasChromeControlFocus, !listOwnsKeyboardFocus, modifiers.isEmpty,
           [36, 76, 49, 123, 124, 125, 126].contains(event.keyCode) {
            return false
        }

        if isCommand, event.charactersIgnoringModifiers?.lowercased() == "k" {
            controller.query = ""
            requestSearchFocus()
            return true
        }

        if isCommand, event.charactersIgnoringModifiers?.lowercased() == "p" {
            togglePinSelected()
            return true
        }

        if isCommand, event.keyCode == 51 || event.keyCode == 117 {
            requestDeleteSelected()
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
            beginAction(id: id, intent: .paste)
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
            beginAction(
                id: selectedID,
                intent: modifiers.isEmpty ? .paste : .copyOnly
            )
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
        beginAction(id: selectedID, intent: .copyOnly)
    }

    public func pasteSelected() {
        guard hasCurrentResults, let selectedID else {
            return
        }
        beginAction(id: selectedID, intent: .paste)
    }

    public func togglePinSelected() {
        guard canMutateHistory, hasCurrentResults, let selectedID else {
            return
        }
        onPinRequested?(selectedID)
    }

    public func requestDeleteSelected() {
        guard canMutateHistory, hasCurrentResults, let selectedID else {
            return
        }
        historyMutationFailure = nil
        pendingDeletionID = selectedID
    }

    public func confirmDeleteSelected() {
        guard let pendingDeletionID else {
            return
        }
        self.pendingDeletionID = nil
        guard canMutateHistory, hasCurrentResults, selectedID == pendingDeletionID else {
            return
        }
        onDeleteRequested?(pendingDeletionID)
    }

    public func cancelDeleteSelected() {
        pendingDeletionID = nil
    }

    public func deleteSelected() {
        requestDeleteSelected()
    }

    public func receiveHistoryMutationResult(_ didSucceed: Bool, action: String) {
        historyMutationFailure = didSucceed ? nil : "Couldn’t \(action). Try again."
    }

    public var canMutateHistory: Bool {
        controller.storageState == .ready
    }

    public func clearHistory(keepingPinned: Bool) {
        guard canMutateHistory else {
            return
        }
        historyMutationFailure = nil
        onClearHistoryRequested?(keepingPinned)
    }

    private func beginAction(id: UUID, intent: ClipboardPasteIntent) {
        guard !isCopying else {
            return
        }

        copyFailure = nil
        pasteStatus = nil
        isCopying = true
        guard let onPasteRequested else {
            isCopying = false
            copyFailure = "Clipboard actions are unavailable. Relaunch Clipboard Manager and try again."
            return
        }
        onPasteRequested(id, intent)
    }

    private func synchronizeSelection() {
        let previousPreview = isPreviewVisible
        selectedID = selection.selectedID
        isPreviewVisible = selection.isPreviewVisible
        if previousPreview != isPreviewVisible {
            onPreviewVisibilityChanged?(isPreviewVisible)
        }
        updatePreviewLoad()
    }

    private func updatePreviewLoad() {
        cancelPreviewLoad()
        guard isPanelPresented, isPreviewVisible, let selectedID else {
            return
        }

        previewLoadGeneration &+= 1
        let generation = previewLoadGeneration
        isLoadingPreview = true
        previewLoadTask = Task { [weak self, controller] in
            let item: ClipboardItem?
            do {
                item = try await controller.loadItem(id: selectedID)
            } catch {
                item = nil
            }
            guard !Task.isCancelled,
                  let self,
                  generation == self.previewLoadGeneration,
                  self.isPreviewVisible,
                  self.selectedID == selectedID
            else {
                return
            }
            self.previewItem = item
            self.previewError = item == nil ? "Preview unavailable for this item." : nil
            self.isLoadingPreview = false
        }
    }

    private func cancelPreviewLoad() {
        previewLoadGeneration &+= 1
        previewLoadTask?.cancel()
        previewLoadTask = nil
        previewItem = nil
        previewError = nil
        isLoadingPreview = false
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

    private func copyOnlyMessage(for reason: ClipboardPasteCopyOnlyReason) -> String? {
        switch reason {
        case .explicitCopy:
            nil
        case .noTarget:
            "Copied to the clipboard. Choose a destination app to paste manually."
        case .targetNotPermitted:
            "Copied to the clipboard. Automatic paste is unavailable for this destination."
        case .permissionUnavailable:
            "Copied to the clipboard. Enable Accessibility to use automatic paste."
        case .targetChanged:
            "Copied to the clipboard. The destination app changed before pasting."
        case .focusTimeout:
            "Copied to the clipboard. The destination did not become ready in time."
        case .clipboardReplaced:
            "Clipboard changed before pasting. Choose the item again."
        case .nativePostUnavailable:
            "Copied to the clipboard. Automatic paste is currently unavailable."
        }
    }

    /// Visibility callbacks need not run when a result publication retains the
    /// same IDs. Keep the last verified visible subset, but arrange it according
    /// to the newly published display order.
    private func reconcileVisibleItems(with itemIDs: [UUID]) {
        let previouslyVisible = Set(visibleItemIDs)
        visibleItemIDs = itemIDs.filter { previouslyVisible.contains($0) }
    }

}
