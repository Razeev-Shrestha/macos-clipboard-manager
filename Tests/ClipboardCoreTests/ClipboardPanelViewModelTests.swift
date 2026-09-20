import AppKit
import XCTest
@testable import ClipboardCore

@MainActor
private final class PanelModelPasteboard: ClipboardPasteboard {
    var changeCount = 0
    var accessState: PasteboardAccessState = .unknown
    private(set) var excludedBundleIdentifiers: Set<String> = []

    func readSnapshotIfStable(expectedChangeCount: Int) -> PasteboardReadResult {
        .skipped(.empty)
    }

    func write(payload: ClipboardPayload) -> PasteboardWriteResult {
        .failed
    }

    func setExcludedBundleIdentifiers(_ identifiers: Set<String>) {
        excludedBundleIdentifiers = identifiers
    }
}

@MainActor
final class ClipboardPanelViewModelTests: XCTestCase {
    func testSameIDPublicationRetainsVerifiedVisibleNumbers() {
        let model = makeModel()
        let first = UUID()
        let second = UUID()

        model.acceptPublishedResults(results([first, second]))
        model.updateVisibleItems([first, second])
        model.acceptPublishedResults(results([first, second]))

        XCTAssertEqual(model.visibleItemIDs, [first, second])
        XCTAssertEqual(model.visibleNumber(for: first), 1)
        XCTAssertEqual(model.visibleNumber(for: second), 2)
    }

    func testReopenDuringPendingQueryDoesNotTreatOldRowsAsCurrent() {
        let controller = makeController()
        let model = ClipboardPanelViewModel(controller: controller)
        let oldRow = UUID()

        model.acceptPublishedResults(results([oldRow]))
        controller.query = "next query"
        model.prepareForOpening(itemIDs: [oldRow])

        XCTAssertFalse(model.hasCurrentResults)
    }

    func testOpeningRequestsScrollEvenWhenTheSelectedIDIsUnchanged() {
        let model = makeModel()
        let row = UUID()
        model.acceptPublishedResults(results([row]))
        let requestBeforeOpening = model.selectionScrollRequest

        model.prepareForOpening(itemIDs: [row])

        XCTAssertEqual(model.selectedID, row)
        XCTAssertEqual(model.selectionScrollRequest, requestBeforeOpening + 1)
    }

    func testReplayedOldResultStaysStaleAfterSearchChanges() {
        let controller = makeController()
        let model = ClipboardPanelViewModel(controller: controller)
        let oldRow = UUID()

        controller.query = "old query"
        let oldResult = results([oldRow], query: "old query")
        model.acceptPublishedResults(oldResult)
        XCTAssertTrue(model.hasCurrentResults)

        controller.query = "new query"
        model.acceptPublishedResults(oldResult)

        XCTAssertFalse(model.hasCurrentResults)
    }

    func testVisibleNumbersFollowTheDisplayedResultOrder() {
        let model = makeModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        model.acceptPublishedResults(results([first, second, third]))
        model.updateVisibleItems([third, second])

        XCTAssertNil(model.visibleNumber(for: first))
        XCTAssertEqual(model.visibleNumber(for: second), 1)
        XCTAssertEqual(model.visibleNumber(for: third), 2)
    }

    func testPublishedReorderReconcilesVerifiedVisibleRowsToResultOrder() {
        let model = makeModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        model.acceptPublishedResults(results([first, second, third]))
        model.updateVisibleItems([second, third])
        model.acceptPublishedResults(results([third, second, first]))

        XCTAssertEqual(model.visibleItemIDs, [third, second])
        XCTAssertEqual(model.visibleNumber(for: third), 1)
        XCTAssertEqual(model.visibleNumber(for: second), 2)
    }

    func testModifiedPrintableTextLeavesListNavigationForSearchEditing() {
        let model = makeModel()
        let first = UUID()
        let second = UUID()
        model.acceptPublishedResults(results([first, second]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 125)))
        XCTAssertTrue(model.listOwnsKeyboardFocus)

        XCTAssertFalse(model.handleKeyDown(keyEvent(
            keyCode: 0,
            modifiers: .shift,
            characters: "A",
            charactersIgnoringModifiers: "a"
        )))
        XCTAssertFalse(model.listOwnsKeyboardFocus)
    }

    func testFunctionAndCapsLockDoNotBlockPlainArrowNavigation() {
        let model = makeModel()
        let first = UUID()
        let second = UUID()
        model.acceptPublishedResults(results([first, second]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(
            keyCode: 125,
            modifiers: [.function, .capsLock]
        )))
        XCTAssertEqual(model.selectedID, second)
    }

    func testChromeFocusLetsNativeControlsHandleNavigationAndActivation() {
        let model = makeModel()
        let itemID = UUID()
        model.acceptPublishedResults(results([itemID]))
        model.select(itemID)
        model.chromeControlFocusChanged(true)
        var requestedPaste = false
        model.onPasteRequested = { _, _ in requestedPaste = true }

        for keyCode: UInt16 in [36, 76, 49, 123, 124, 125, 126] {
            XCTAssertFalse(model.handleKeyDown(keyEvent(keyCode: keyCode)))
        }
        XCTAssertFalse(model.listOwnsKeyboardFocus)
        XCTAssertFalse(model.isPreviewVisible)
        XCTAssertFalse(requestedPaste)

        model.chromeControlFocusChanged(false)
        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 36)))
        XCTAssertTrue(requestedPaste)
    }

    func testChromeFocusPreservesCommandCopyAndPointerPreview() {
        let model = makeModel()
        let itemID = UUID()
        model.acceptPublishedResults(results([itemID]))
        model.chromeControlFocusChanged(true)
        var intent: ClipboardPasteIntent?
        model.onPasteRequested = { _, value in intent = value }
        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 36, modifiers: .command)))
        XCTAssertEqual(intent, .copyOnly)

        model.select(itemID)
        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 49)))
        XCTAssertTrue(model.isPreviewVisible)
    }

    func testReturnRequestsPasteForTheCurrentSelection() {
        let model = makeModel()
        let itemID = UUID()
        var requested: [(UUID, ClipboardPasteIntent)] = []
        model.onPasteRequested = { itemID, intent in
            requested.append((itemID, intent))
        }
        model.acceptPublishedResults(results([itemID]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 36)))
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.0, itemID)
        XCTAssertEqual(requested.first?.1, .paste)
        XCTAssertTrue(model.isCopying)
    }

    func testCommandReturnRequestsCopyOnlyForTheCurrentSelection() {
        let model = makeModel()
        let itemID = UUID()
        var requested: [(UUID, ClipboardPasteIntent)] = []
        model.onPasteRequested = { itemID, intent in
            requested.append((itemID, intent))
        }
        model.acceptPublishedResults(results([itemID]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(
            keyCode: 36,
            modifiers: .command,
            characters: "\r",
            charactersIgnoringModifiers: "\r"
        )))
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.0, itemID)
        XCTAssertEqual(requested.first?.1, .copyOnly)
        XCTAssertTrue(model.isCopying)
    }

    func testVisibleCommandNumberRequestsPasteForThatVisibleItem() {
        let model = makeModel()
        let first = UUID()
        let second = UUID()
        var requested: [(UUID, ClipboardPasteIntent)] = []
        model.onPasteRequested = { itemID, intent in
            requested.append((itemID, intent))
        }
        model.acceptPublishedResults(results([first, second]))
        model.updateVisibleItems([first, second])

        XCTAssertTrue(model.handleKeyDown(keyEvent(
            keyCode: 19,
            modifiers: .command,
            characters: "2",
            charactersIgnoringModifiers: "2"
        )))
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.0, second)
        XCTAssertEqual(requested.first?.1, .paste)
        XCTAssertEqual(model.selectedID, second)
    }

    func testPreviewCopyRequestsCopyOnly() {
        let model = makeModel()
        let itemID = UUID()
        var requested: [(UUID, ClipboardPasteIntent)] = []
        model.onPasteRequested = { itemID, intent in
            requested.append((itemID, intent))
        }
        model.acceptPublishedResults(results([itemID]))

        model.copySelected()

        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.0, itemID)
        XCTAssertEqual(requested.first?.1, .copyOnly)
    }

    func testCommandPRequestsPinToggleForReadyStorage() async {
        let model = await makeReadyModel()
        let itemID = UUID()
        var requestedID: UUID?
        model.onPinRequested = { requestedID = $0 }
        model.acceptPublishedResults(results([itemID]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(
            keyCode: 35,
            modifiers: .command,
            characters: "p",
            charactersIgnoringModifiers: "p"
        )))
        XCTAssertEqual(requestedID, itemID)
        await model.controller.shutdown()
    }

    func testCommandDeleteRequiresConfirmationBeforeDeletion() async {
        let model = await makeReadyModel()
        let itemID = UUID()
        var requestedID: UUID?
        model.onDeleteRequested = { requestedID = $0 }
        model.acceptPublishedResults(results([itemID]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 51, modifiers: .command)))
        XCTAssertEqual(model.pendingDeletionID, itemID)
        XCTAssertNil(requestedID)

        model.confirmDeleteSelected()
        XCTAssertEqual(requestedID, itemID)
        XCTAssertNil(model.pendingDeletionID)
        await model.controller.shutdown()
    }

    func testPointerSelectionThenSpaceOpensPreviewWithoutCapturingPrintableSearch() {
        let model = makeModel()
        let first = UUID()
        let second = UUID()
        model.acceptPublishedResults(results([first, second]))

        model.select(second)
        XCTAssertTrue(model.listOwnsKeyboardFocus)
        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 49, characters: " ", charactersIgnoringModifiers: " ")))
        XCTAssertTrue(model.isPreviewVisible)

        XCTAssertFalse(model.handleKeyDown(keyEvent(
            keyCode: 0,
            characters: "a",
            charactersIgnoringModifiers: "a"
        )))
        XCTAssertFalse(model.listOwnsKeyboardFocus)
    }

    func testPointerSelectionThenRightArrowOpensPreview() {
        let model = makeModel()
        let itemID = UUID()
        model.acceptPublishedResults(results([itemID]))

        model.select(itemID)

        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 124)))
        XCTAssertTrue(model.isPreviewVisible)
    }

    func testHistoryMutationFailureIsVisible() {
        let model = makeModel()

        model.receiveHistoryMutationResult(false, action: "delete this item")

        XCTAssertEqual(model.historyMutationFailure, "Couldn’t delete this item. Try again.")
    }

    func testClearHistoryRoutesRetentionChoiceForReadyStorage() async {
        let model = await makeReadyModel()
        var keepingPinned: Bool?
        model.onClearHistoryRequested = { keepingPinned = $0 }

        model.clearHistory(keepingPinned: true)

        XCTAssertEqual(keepingPinned, true)
        await model.controller.shutdown()
    }

    func testUnavailableStorageBlocksKeyboardAndHistoryMutations() {
        let model = makeModel()
        let itemID = UUID()
        var pinRequests = 0
        var deleteRequests = 0
        var clearRequests = 0
        model.onPinRequested = { _ in pinRequests += 1 }
        model.onDeleteRequested = { _ in deleteRequests += 1 }
        model.onClearHistoryRequested = { _ in clearRequests += 1 }
        model.acceptPublishedResults(results([itemID]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(
            keyCode: 35,
            modifiers: .command,
            characters: "p",
            charactersIgnoringModifiers: "p"
        )))
        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 51, modifiers: .command)))
        model.clearHistory(keepingPinned: true)

        XCTAssertFalse(model.canMutateHistory)
        XCTAssertNil(model.pendingDeletionID)
        XCTAssertEqual(pinRequests, 0)
        XCTAssertEqual(deleteRequests, 0)
        XCTAssertEqual(clearRequests, 0)
    }

    func testClosedPanelDoesNotRestartPreviewLoadFromPublishedResults() {
        let model = makeModel()
        let itemID = UUID()
        model.prepareForOpening(itemIDs: [itemID])
        model.acceptPublishedResults(results([itemID]))
        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 125)))
        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 49)))
        model.didClose()

        model.acceptPublishedResults(results([itemID]))

        XCTAssertFalse(model.isLoadingPreview)
        XCTAssertNil(model.previewItem)
    }

    func testStaleResultsDoNotRequestPaste() {
        let controller = makeController()
        let model = ClipboardPanelViewModel(controller: controller)
        let itemID = UUID()
        var requestCount = 0
        model.onPasteRequested = { _, _ in
            requestCount += 1
        }
        model.acceptPublishedResults(results([itemID]))
        controller.query = "new query"

        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 36)))
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(model.isCopying)
    }

    func testCancelledOutcomeClearsBusyStateWithoutClaimingInsertion() {
        let model = makeModel()
        let itemID = UUID()
        model.onPasteRequested = { _, _ in }
        model.acceptPublishedResults(results([itemID]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 36)))
        XCTAssertTrue(model.isCopying)

        model.receivePasteOutcome(.cancelled)

        XCTAssertFalse(model.isCopying)
        XCTAssertNil(model.pasteStatus)
    }

    func testCancellationAfterCloseLetsTheReopenedPanelStartAnotherAction() {
        let model = makeModel()
        let itemID = UUID()
        var requested: [(UUID, ClipboardPasteIntent)] = []
        model.onPasteRequested = { itemID, intent in
            requested.append((itemID, intent))
        }
        model.acceptPublishedResults(results([itemID]))

        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 36)))
        XCTAssertTrue(model.isCopying)

        model.didClose()
        XCTAssertTrue(model.isCopying)

        model.receivePasteOutcome(.cancelled)
        XCTAssertFalse(model.isCopying)

        model.prepareForOpening(itemIDs: [itemID])
        XCTAssertTrue(model.handleKeyDown(keyEvent(keyCode: 36)))
        XCTAssertEqual(requested.map(\.0), [itemID, itemID])
        XCTAssertEqual(requested.map(\.1), [.paste, .paste])
    }

    func testClipboardReplacedOutcomeTellsUserToChooseTheItemAgain() {
        let model = makeModel()

        model.receivePasteOutcome(.copiedOnly(.clipboardReplaced))

        XCTAssertEqual(model.pasteStatus, "Clipboard changed before pasting. Choose the item again.")
    }

    func testFallbackGuidanceSurvivesReopeningUntilTheNextAction() {
        let model = makeModel()
        let itemID = UUID()
        model.acceptPublishedResults(results([itemID]))
        model.receivePasteOutcome(.copiedOnly(.clipboardReplaced))

        model.prepareForOpening(itemIDs: [itemID])

        XCTAssertEqual(model.pasteStatus, "Clipboard changed before pasting. Choose the item again.")

        model.onPasteRequested = { _, _ in }
        model.copySelected()

        XCTAssertNil(model.pasteStatus)
    }

    private func makeModel() -> ClipboardPanelViewModel {
        ClipboardPanelViewModel(controller: makeController())
    }

    private func makeReadyModel() async -> ClipboardPanelViewModel {
        let model = makeModel()
        await model.controller.start()
        XCTAssertEqual(model.controller.storageState, .ready)
        return model
    }

    private func results(
        _ itemIDs: [UUID],
        query: String = "",
        filter: ClipboardHistoryFilter = .all
    ) -> ClipboardHistoryResults {
        ClipboardHistoryResults(items: itemIDs.map(makeMetadataItem), query: query, filter: filter)
    }

    private func makeMetadataItem(id: UUID) -> ClipboardItem {
        ClipboardItem(
            id: id,
            capture: ClipboardCapture(
                payload: ClipboardPayload(
                    primaryTypeIdentifier: "public.utf8-plain-text",
                    representations: [],
                    plainText: "synthetic panel item"
                ),
                primaryType: .text,
                searchableText: "synthetic panel item"
            ),
            createdAt: .distantPast
        )
    }

    private func makeController() -> ClipboardHistoryController {
        ClipboardHistoryController(
            pasteboard: PanelModelPasteboard(),
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipboardPanelViewModel-\(UUID().uuidString)")
                .appendingPathComponent("history.sqlite")
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = "",
        charactersIgnoringModifiers: String = ""
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Unable to create a synthetic keyboard event.")
        }
        return event
    }
}
