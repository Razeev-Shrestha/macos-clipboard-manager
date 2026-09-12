import AppKit
import XCTest
@testable import ClipboardCore

@MainActor
private final class PanelModelPasteboard: ClipboardPasteboard {
    var changeCount = 0
    var accessState: PasteboardAccessState = .unknown

    func readSnapshotIfStable(expectedChangeCount: Int) -> PasteboardReadResult {
        .skipped(.empty)
    }

    func write(payload: ClipboardPayload) -> PasteboardWriteResult {
        .failed
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
