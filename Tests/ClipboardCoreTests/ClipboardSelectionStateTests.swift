import Foundation
import XCTest
@testable import ClipboardCore

final class ClipboardSelectionStateTests: XCTestCase {
    func testOpeningSelectsNewestItemAndClosesPreview() {
        let first = UUID()
        let second = UUID()
        var state = ClipboardSelectionState()
        state.togglePreview()

        state.resetForOpening(itemIDs: [first, second])

        XCTAssertEqual(state.itemIDs, [first, second])
        XCTAssertEqual(state.selectedID, first)
        XCTAssertFalse(state.isPreviewVisible)
    }

    func testUpdatePreservesSelectedIdentityAcrossNewArrivalAndReordering() {
        let first = UUID()
        let selected = UUID()
        let newest = UUID()
        var state = ClipboardSelectionState()
        state.resetForOpening(itemIDs: [first, selected])
        state.select(selected)

        state.updateItems([newest, selected, first])

        XCTAssertEqual(state.selectedID, selected)
    }

    func testReplacingItemsResetsSelectionToFirstVisibleRow() {
        let original = UUID()
        let replacement = UUID()
        var state = ClipboardSelectionState()
        state.resetForOpening(itemIDs: [original])

        state.updateItems([replacement], resetSelection: true)

        XCTAssertEqual(state.selectedID, replacement)
    }

    func testRemovingSelectionChoosesRowAtTheSamePositionOrPreviousLastRow() {
        let first = UUID()
        let selected = UUID()
        let third = UUID()
        var state = ClipboardSelectionState()
        state.resetForOpening(itemIDs: [first, selected, third])
        state.select(selected)

        state.updateItems([first, third])
        XCTAssertEqual(state.selectedID, third)

        state.select(third)
        state.updateItems([first])
        XCTAssertEqual(state.selectedID, first)
    }

    func testMovementClampsAndEmptyStateIsSafe() {
        let first = UUID()
        let second = UUID()
        var state = ClipboardSelectionState()

        state.move(by: 1)
        XCTAssertNil(state.selectedID)

        state.updateItems([first, second])
        state.move(by: 10)
        XCTAssertEqual(state.selectedID, second)
        state.move(by: -10)
        XCTAssertEqual(state.selectedID, first)
    }

    func testNumberedSelectionOnlyUsesVisibleOneThroughNine() {
        let ids = (0 ..< 10).map { _ in UUID() }
        var state = ClipboardSelectionState()
        state.resetForOpening(itemIDs: ids)

        XCTAssertEqual(state.selectVisibleItem(number: 2), ids[1])
        XCTAssertEqual(state.selectedID, ids[1])
        XCTAssertNil(state.selectVisibleItem(number: 10))
        XCTAssertNil(state.selectVisibleItem(number: 0))
        XCTAssertEqual(state.selectedID, ids[1])
    }
}
