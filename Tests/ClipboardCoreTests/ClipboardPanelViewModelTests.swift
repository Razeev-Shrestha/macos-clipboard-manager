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
