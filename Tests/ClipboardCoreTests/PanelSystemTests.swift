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

        let contentRect = NSWindow.contentRect(
            forFrameRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable]
        )
        XCTAssertEqual(contentRect.size, NSSize(width: 760, height: 520))
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
        XCTAssertFalse(controller.hasPresentedWindow)
        XCTAssertNil(controller.previousApplication)
        XCTAssertTrue(controller.contentView === contentView)
    }

    func testPanelHasUsableNativeWindowControlsAndSeparateTitlebar() throws {
        let contentView = NSView(frame: .zero)
        let controller = ClipboardPanelController(contentView: contentView)
        let window = try XCTUnwrap(contentView.window)

        XCTAssertEqual(window.title, "Clipboard Manager")
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertTrue(
            window.collectionBehavior.contains(.managed),
            "The clipboard panel must participate in Mission Control previews."
        )
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.contentMinSize.width, 620)
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titlebarHeight, 0)
        XCTAssertEqual(window.contentMinSize.height - titlebarHeight, 420)
        XCTAssertEqual(window.contentLayoutRect.size, NSSize(width: 760, height: 520))
        XCTAssertEqual(contentView.safeAreaRect.size, window.contentLayoutRect.size)
        XCTAssertTrue(controller.contentView === contentView)

        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(buttonType))
            XCTAssertFalse(button.isHidden)
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.window === window)
        }
    }

    func testReturningFromAuxiliaryWindowRestoresProvidedExternalDestination() {
        let originalApplication = PanelTestApplication(processIdentifier: 101)
        var frontmost: NSRunningApplication? = originalApplication
        let controller = ClipboardPanelController(
            contentView: NSView(frame: .zero),
            frontmostApplication: { frontmost }
        )
        controller.show()
        XCTAssertTrue(controller.previousApplication === originalApplication)
        controller.close(restoringFocus: false)
        XCTAssertNil(controller.previousApplication)

        frontmost = NSRunningApplication.current
        var destinationAtWillShow: NSRunningApplication?
        controller.onWillShow = { destinationAtWillShow = controller.previousApplication }
        defer {
            controller.onWillShow = nil
            controller.close(restoringFocus: false)
        }
        controller.show(previousApplication: originalApplication)

        XCTAssertTrue(controller.previousApplication === originalApplication)
        XCTAssertTrue(destinationAtWillShow === originalApplication)
        XCTAssertTrue(controller.hasPresentedWindow)
    }

    func testLiveFrontmostApplicationOverridesProvidedFallbackDestination() {
        let fallback = PanelTestApplication(processIdentifier: 101)
        let frontmost = PanelTestApplication(processIdentifier: 102)
        let controller = ClipboardPanelController(
            contentView: NSView(frame: .zero),
            frontmostApplication: { frontmost }
        )
        defer { controller.close(restoringFocus: false) }

        controller.show(previousApplication: fallback)

        XCTAssertTrue(controller.previousApplication === frontmost)
    }

    func testReturningIgnoresOwnAndTerminatedFallbackDestinations() {
        let controller = ClipboardPanelController(
            contentView: NSView(frame: .zero),
            frontmostApplication: { NSRunningApplication.current }
        )
        defer { controller.close(restoringFocus: false) }

        for fallback in [NSRunningApplication.current, PanelTestApplication(processIdentifier: 101, isTerminated: true)] {
            controller.show(previousApplication: fallback)
            XCTAssertNil(controller.previousApplication)
            controller.close(restoringFocus: false)
        }
    }

    func testNativeCloseReusesPanelAndNotifiesOnce() throws {
        let contentView = NSView(frame: .zero)
        let controller = ClipboardPanelController(contentView: contentView)
        let window = try XCTUnwrap(contentView.window)
        var closes = 0
        controller.onDidClose = { closes += 1 }
        window.orderFront(nil)

        window.performClose(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(controller.contentView === contentView)
        XCTAssertTrue(contentView.window === window)
        controller.close(restoringFocus: false)
        XCTAssertEqual(closes, 1)
    }

    func testResigningActiveKeepsPresentedPanelForMissionControl() throws {
        let contentView = NSView(frame: .zero)
        let controller = ClipboardPanelController(contentView: contentView)
        let window = try XCTUnwrap(contentView.window)
        defer { controller.close(restoringFocus: false) }

        controller.show()
        XCTAssertTrue(controller.hasPresentedWindow)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )

        XCTAssertTrue(
            controller.hasPresentedWindow,
            "The clipboard panel must remain presented while Mission Control snapshots windows."
        )
        XCTAssertTrue(
            window.isVisible,
            "The clipboard panel must remain visible after the app resigns active."
        )
    }

    func testMinimizedPanelReopensThroughToggleAndCanCloseAgain() throws {
        let contentView = NSView(frame: .zero)
        let controller = ClipboardPanelController(contentView: contentView)
        let window = try XCTUnwrap(contentView.window)
        var openings = 0
        var closes = 0
        controller.onWillShow = { openings += 1 }
        controller.onDidClose = { closes += 1 }
        controller.show()
        defer { controller.close(restoringFocus: false) }
        let previousProcessID = controller.previousApplication?.processIdentifier

        let didMiniaturize = expectation(forNotification: NSWindow.didMiniaturizeNotification, object: window)
        window.miniaturize(nil)
        wait(for: [didMiniaturize], timeout: 2)
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(controller.hasPresentedWindow)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(closes, 0)
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertEqual(controller.previousApplication?.processIdentifier, previousProcessID)

        let didDeminiaturize = expectation(forNotification: NSWindow.didDeminiaturizeNotification, object: window)
        controller.toggle()
        wait(for: [didDeminiaturize], timeout: 2)

        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(openings, 2)
        controller.close(restoringFocus: false)
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(controller.hasPresentedWindow)
        XCTAssertEqual(closes, 1)
    }

    func testStandardZoomFrameUsesVisibleScreen() throws {
        let contentView = NSView(frame: .zero)
        let controller = ClipboardPanelController(contentView: contentView)
        let window = try XCTUnwrap(contentView.window)
        let screen = try XCTUnwrap(NSScreen.main)
        window.setFrameOrigin(screen.visibleFrame.origin)

        XCTAssertEqual(
            controller.windowWillUseStandardFrame(window, defaultFrame: window.frame),
            window.screen?.visibleFrame
        )
    }

    func testNativeDeminiaturizationPreparesOpeningAndUsesLatestExternalApplication() throws {
        let contentView = NSView(frame: .zero)
        let originalApplication = PanelTestApplication(processIdentifier: 101)
        let latestApplication = PanelTestApplication(processIdentifier: 102)
        var frontmost: NSRunningApplication? = originalApplication
        let controller = ClipboardPanelController(contentView: contentView, frontmostApplication: { frontmost })
        let window = try XCTUnwrap(contentView.window)
        var openings = 0
        controller.onWillShow = { openings += 1 }
        controller.show()
        defer { controller.close(restoringFocus: false) }
        XCTAssertTrue(controller.previousApplication === originalApplication)

        let didMiniaturize = expectation(forNotification: NSWindow.didMiniaturizeNotification, object: window)
        window.miniaturize(nil)
        wait(for: [didMiniaturize], timeout: 2)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: latestApplication]
        )
        XCTAssertTrue(controller.previousApplication === latestApplication)

        // Clicking the Dock thumbnail activates our app before AppKit finishes
        // restoring the window. It must not replace the external destination.
        frontmost = NSRunningApplication.current
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )
        let didDeminiaturize = expectation(forNotification: NSWindow.didDeminiaturizeNotification, object: window)
        window.deminiaturize(nil)
        wait(for: [didDeminiaturize], timeout: 2)

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(openings, 2)
        XCTAssertTrue(controller.previousApplication === latestApplication)
        controller.close(restoringFocus: false)
        XCTAssertNil(controller.previousApplication)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: originalApplication]
        )
        XCTAssertNil(controller.previousApplication)
    }

    func testNativeZoomExpandsAndRestoresTheWindow() throws {
        let contentView = NSView(frame: .zero)
        let controller = ClipboardPanelController(contentView: contentView)
        let window = try XCTUnwrap(contentView.window)
        let screen = try XCTUnwrap(NSScreen.main)
        window.setFrame(
            ClipboardPanelController.panelFrame(for: screen.visibleFrame, expanded: false),
            display: false
        )
        window.orderFront(nil)
        defer { controller.close(restoringFocus: false) }
        let originalFrame = window.frame

        window.performZoom(nil)
        XCTAssertEqual(window.frame, screen.visibleFrame)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))

        window.performZoom(nil)
        XCTAssertEqual(window.frame, originalFrame)
    }

    private func tryUnwrap(_ frame: NSRect?) -> NSRect {
        guard let frame else {
            fatalError("expected a screen frame")
        }
        return frame
    }
}

private final class PanelTestApplication: NSRunningApplication, @unchecked Sendable {
    private let fixtureProcessIdentifier: pid_t
    private let fixtureIsTerminated: Bool

    init(processIdentifier: pid_t, isTerminated: Bool = false) {
        fixtureProcessIdentifier = processIdentifier
        fixtureIsTerminated = isTerminated
        super.init()
    }

    override var processIdentifier: pid_t { fixtureProcessIdentifier }
    override var isTerminated: Bool { fixtureIsTerminated }
}
