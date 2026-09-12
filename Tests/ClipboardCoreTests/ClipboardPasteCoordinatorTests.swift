import AppKit
import Foundation
import XCTest
@testable import ClipboardCore

@MainActor
final class ClipboardPasteCoordinatorTests: XCTestCase {
    func testTargetCaptureRejectsTheManagerProcess() {
        let application = NSRunningApplication.current

        XCTAssertNil(
            ClipboardPasteTarget.capture(previousApplication: application)
        )
    }

    func testCopyOnlyAlwaysCopiesAndClosesWithoutNativeAccess() async {
        let native = NativeSpy()
        var outcomes: [ClipboardPasteOutcome] = []
        var closeCount = 0
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 11) },
            restoreStillCurrent: { _ in true },
            closePanel: {
                closeCount += 1
                coordinator?.panelDidClose()
            },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(
            itemID: UUID(),
            intent: .copyOnly,
            target: nil
        )
        await settle()

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(outcomes, [.copiedOnly(.explicitCopy)])
        XCTAssertEqual(native.accessibilityChecks, 0)
        XCTAssertEqual(native.postAccessChecks, 0)
        XCTAssertEqual(native.postedPIDs, [])
    }

    func testMissingTargetFallsBackToCopyOnlyWithoutPermissionChecks() async {
        let native = NativeSpy()
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 12) },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: nil)
        await settle()

        XCTAssertEqual(outcomes, [.copiedOnly(.noTarget)])
        XCTAssertEqual(native.accessibilityChecks, 0)
        XCTAssertEqual(native.postAccessChecks, 0)
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testDisallowedTargetFallsBackWithoutNativeAccess() async {
        let native = NativeSpy()
        let target = makeTarget()
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 13) },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            permittedTarget: { _ in false },
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()

        XCTAssertEqual(outcomes, [.copiedOnly(.targetNotPermitted)])
        XCTAssertEqual(native.accessibilityChecks, 0)
        XCTAssertEqual(native.postAccessChecks, 0)
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testCopyFailureNeverClosesOrPosts() async {
        let native = NativeSpy()
        var outcomes: [ClipboardPasteOutcome] = []
        var closeCount = 0
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in nil },
            restoreStillCurrent: { _ in true },
            closePanel: { closeCount += 1; coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: makeTarget())
        await settle()

        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(outcomes, [.copyFailed])
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testExpectedCloseDoesNotCancelSuccessfulPaste() async {
        let native = NativeSpy()
        let target = makeTarget()
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 14) },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()

        XCTAssertEqual(outcomes, [.pasteRequested])
        XCTAssertEqual(native.postedPIDs, [target.processIdentifier])
    }

    func testPermissionRevocationBeforePostingFallsBackAndRetainsCopy() async {
        let native = NativeSpy()
        native.accessibilityResult = { prompt in prompt }
        let target = makeTarget()
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 15) },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()

        XCTAssertEqual(outcomes, [.copiedOnly(.permissionUnavailable)])
        XCTAssertTrue(native.postedPIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(native.accessibilityChecks, 2)
    }

    func testEventPostingAccessRevocationFallsBackWithoutPosting() async {
        let native = NativeSpy()
        native.postEventResult = false
        let target = makeTarget()
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 151) },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()

        XCTAssertEqual(outcomes, [.copiedOnly(.nativePostUnavailable)])
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testClipboardReplacementAfterCopyPreventsPost() async {
        let native = NativeSpy()
        let target = makeTarget()
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 16) },
            restoreStillCurrent: { _ in false },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()

        XCTAssertEqual(outcomes, [.copiedOnly(.clipboardReplaced)])
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testClipboardReplacementDuringFinalPermissionCheckPreventsPost() async {
        let native = NativeSpy()
        var receiptIsCurrent = true
        native.onPostEventAccess = {
            receiptIsCurrent = false
        }
        let target = makeTarget()
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 161) },
            restoreStillCurrent: { _ in receiptIsCurrent },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()

        XCTAssertEqual(outcomes, [.copiedOnly(.clipboardReplaced)])
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testTargetDeathAndFocusTimeoutNeverPost() async {
        let native = NativeSpy()
        native.targetIsUsable = { _ in false }
        let target = makeTarget()
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 17) },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) },
            focusTimeout: .zero
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()
        XCTAssertEqual(outcomes, [.copiedOnly(.targetChanged)])
        XCTAssertTrue(native.postedPIDs.isEmpty)

        native.targetIsUsable = { _ in true }
        native.frontmostMatchesTarget = { _, _ in false }
        outcomes.removeAll()
        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()
        XCTAssertEqual(outcomes, [.copiedOnly(.focusTimeout)])
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testUnrelatedFrontmostAppAbortsBeforeTargetReturns() async {
        let native = NativeSpy()
        let target = makeTarget()
        var frontmostChecks = 0
        native.frontmostMatchesTarget = { _, _ in
            frontmostChecks += 1
            return frontmostChecks > 1
        }
        native.frontmostIsUnrelated = { _, _ in
            frontmostChecks == 1
        }
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in ClipboardRestoreReceipt(changeCount: 171) },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) },
            focusTimeout: .milliseconds(100)
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()

        XCTAssertEqual(outcomes, [.copiedOnly(.targetChanged)])
        XCTAssertEqual(frontmostChecks, 1)
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testDismissalDuringHydrationCancelsStaleCompletion() async {
        let native = NativeSpy()
        let target = makeTarget()
        var continuation: CheckedContinuation<ClipboardRestoreReceipt?, Never>?
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in
                await withCheckedContinuation { (value: CheckedContinuation<ClipboardRestoreReceipt?, Never>) in
                    continuation = value
                }
            },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()
        coordinator?.panelDidClose()
        continuation?.resume(returning: ClipboardRestoreReceipt(changeCount: 18))
        await settle()

        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertTrue(native.postedPIDs.isEmpty)
    }

    func testSupersedingActionCannotBeClearedByStaleCompletion() async {
        let native = NativeSpy()
        let target = makeTarget()
        var firstContinuation: CheckedContinuation<ClipboardRestoreReceipt?, Never>?
        var outcomes: [ClipboardPasteOutcome] = []
        var coordinator: ClipboardPasteCoordinator?
        var copyCount = 0
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in
                copyCount += 1
                if copyCount == 1 {
                    return await withCheckedContinuation { (value: CheckedContinuation<ClipboardRestoreReceipt?, Never>) in
                        firstContinuation = value
                    }
                }
                return ClipboardRestoreReceipt(changeCount: 19)
            },
            restoreStillCurrent: { _ in true },
            closePanel: { coordinator?.panelDidClose() },
            native: native.boundary,
            onOutcome: { outcomes.append($0) }
        )

        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()
        coordinator?.begin(itemID: UUID(), intent: .paste, target: target)
        await settle()
        firstContinuation?.resume(returning: ClipboardRestoreReceipt(changeCount: 20))
        await settle()

        XCTAssertEqual(outcomes, [.pasteRequested])
        XCTAssertEqual(native.postedPIDs, [target.processIdentifier])
    }

    func testAutomaticPasteStatusIsReadOnlyAndExplicitRequestPrompts() {
        let native = NativeSpy()
        native.accessibilityResult = { prompt in prompt }
        var coordinator: ClipboardPasteCoordinator?
        coordinator = ClipboardPasteCoordinator(
            copyItem: { _ in nil },
            restoreStillCurrent: { _ in true },
            closePanel: {},
            native: native.boundary,
            onOutcome: { _ in }
        )

        XCTAssertFalse(coordinator?.canAutomaticallyPaste == true)
        coordinator?.requestAccessibilityAccess()
        XCTAssertEqual(native.accessibilityChecks, 2)
    }

    private func makeTarget() -> ClipboardPasteTarget {
        let application = NSRunningApplication.current
        return ClipboardPasteTarget(
            application: application,
            processIdentifier: application.processIdentifier
        )
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

@MainActor
private final class NativeSpy {
    var accessibilityResult: (Bool) -> Bool = { _ in true }
    var postEventResult = true
    var frontmostMatchesTarget: (ClipboardPasteTarget, NSRunningApplication?) -> Bool = { target, frontmost in
        frontmost?.processIdentifier == target.processIdentifier
    }
    var targetIsUsable: (ClipboardPasteTarget) -> Bool = { _ in true }
    var frontmostIsUnrelated: (ClipboardPasteTarget, NSRunningApplication?) -> Bool = { _, _ in false }
    var accessibilityChecks = 0
    var postAccessChecks = 0
    var postedPIDs: [pid_t] = []
    var onPostEventAccess: (() -> Void)?

    var boundary: ClipboardPasteNativeBoundary {
        var boundary = ClipboardPasteNativeBoundary(
            accessibilityTrusted: { [weak self] prompt in
                self?.accessibilityChecks += 1
                return self?.accessibilityResult(prompt) ?? false
            },
            postEventAccess: { [weak self] in
                self?.postAccessChecks += 1
                self?.onPostEventAccess?()
                return self?.postEventResult ?? false
            },
            frontmostApplication: {
                NSRunningApplication.current
            },
            postCommandV: { [weak self] pid in
                self?.postedPIDs.append(pid)
            },
            sleep: { _ in }
        )
        boundary.targetIsUsable = { [weak self] target in
            self?.targetIsUsable(target) ?? false
        }
        boundary.frontmostMatchesTarget = { [weak self] target, frontmost in
            self?.frontmostMatchesTarget(target, frontmost) ?? false
        }
        boundary.frontmostIsUnrelated = { [weak self] target, frontmost in
            self?.frontmostIsUnrelated(target, frontmost) ?? false
        }
        return boundary
    }
}
