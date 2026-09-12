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

    func testRecoveryKeepsPanelOnAttachedNegativeOriginDisplay() {
        let left = NSRect(x: -1_280, y: 0, width: 1_280, height: 800)
        let main = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let panel = NSRect(x: -900, y: 120, width: 760, height: 520)

        XCTAssertEqual(
            ClipboardPanelController.recoveryVisibleFrame(
                for: panel,
                visibleFrames: [left, main],
                preferredVisibleFrame: main
            ),
            left
        )
    }

    func testRecoveryUsesCurrentPreferredDisplayAfterSelectedDisplayIsRemoved() {
        let removedDisplayPanel = NSRect(x: 2_400, y: 100, width: 760, height: 520)
        let remaining = NSRect(x: 0, y: 0, width: 800, height: 500)

        let recovered = ClipboardPanelController.recoveryVisibleFrame(
            for: removedDisplayPanel,
            visibleFrames: [remaining],
            preferredVisibleFrame: remaining
        )

        XCTAssertEqual(recovered, remaining)
        XCTAssertEqual(
            ClipboardPanelController.panelFrame(for: tryUnwrap(recovered), expanded: true),
            remaining
        )
    }

    func testRecoveryUsesLargestOverlapWhenThePanelCrossesDisplays() {
        let first = NSRect(x: 0, y: 0, width: 900, height: 700)
        let second = NSRect(x: 900, y: 0, width: 900, height: 700)
        let panel = NSRect(x: 650, y: 100, width: 760, height: 520)

        XCTAssertEqual(
            ClipboardPanelController.recoveryVisibleFrame(
                for: panel,
                visibleFrames: [first, second],
                preferredVisibleFrame: first
            ),
            second
        )
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

    private func tryUnwrap(_ frame: NSRect?) -> NSRect {
        guard let frame else {
            fatalError("expected a screen frame")
        }
        return frame
    }
}
