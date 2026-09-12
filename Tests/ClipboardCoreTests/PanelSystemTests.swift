import AppKit
import XCTest
@testable import ClipboardCore

@MainActor
final class PanelSystemTests: XCTestCase {
    func testCompactPanelFrameIsCenteredSlightlyAboveCenter() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)

        let frame = ClipboardPanelController.panelFrame(
            for: visibleFrame,
            expanded: false
        )

        XCTAssertEqual(frame.size, NSSize(width: 760, height: 520))
        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 0.5)
        XCTAssertGreaterThan(frame.midY, visibleFrame.midY)
        XCTAssertLessThanOrEqual(frame.minX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(frame.maxX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(frame.minY, visibleFrame.maxY)
        XCTAssertGreaterThanOrEqual(frame.maxY, visibleFrame.minY)
    }

    func testExpandedPanelFrameClampsToVisibleFrame() {
        let visibleFrame = NSRect(x: 12, y: 24, width: 800, height: 500)

        let frame = ClipboardPanelController.panelFrame(
            for: visibleFrame,
            expanded: true
        )

        XCTAssertEqual(frame.size, visibleFrame.size)
        XCTAssertEqual(frame, visibleFrame)
    }

    func testFocusRestorationRequiresPreviousLiveAppAndPanelOwnership() {
        let ownProcessID: pid_t = 100
        let previousProcessID: pid_t = 200

        XCTAssertTrue(
            ClipboardPanelController.shouldRestoreFocus(
                restoringFocus: true,
                previousProcessIdentifier: previousProcessID,
                previousApplicationTerminated: false,
                frontmostProcessIdentifier: ownProcessID,
                ownProcessIdentifier: ownProcessID
            )
        )
        XCTAssertFalse(
            ClipboardPanelController.shouldRestoreFocus(
                restoringFocus: true,
                previousProcessIdentifier: previousProcessID,
                previousApplicationTerminated: true,
                frontmostProcessIdentifier: ownProcessID,
                ownProcessIdentifier: ownProcessID
            )
        )
        XCTAssertFalse(
            ClipboardPanelController.shouldRestoreFocus(
                restoringFocus: true,
                previousProcessIdentifier: previousProcessID,
                previousApplicationTerminated: false,
                frontmostProcessIdentifier: 300,
                ownProcessIdentifier: ownProcessID
            )
        )
        XCTAssertFalse(
            ClipboardPanelController.shouldRestoreFocus(
                restoringFocus: false,
                previousProcessIdentifier: previousProcessID,
                previousApplicationTerminated: false,
                frontmostProcessIdentifier: ownProcessID,
                ownProcessIdentifier: ownProcessID
            )
        )
    }

    func testPanelStartsHiddenWithProvidedContentView() {
        let contentView = NSView(frame: .zero)
        let controller = ClipboardPanelController(contentView: contentView)

        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(controller.previousApplication)
        XCTAssertTrue(controller.contentView === contentView)
    }
}
