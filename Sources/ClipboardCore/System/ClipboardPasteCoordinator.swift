@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public enum ClipboardPasteIntent: Equatable, Sendable {
    case paste
    case copyOnly
}

public enum ClipboardPasteCopyOnlyReason: Equatable, Sendable {
    case explicitCopy
    case noTarget
    case targetNotPermitted
    case permissionUnavailable
    case targetChanged
    case focusTimeout
    case clipboardReplaced
    case nativePostUnavailable
}

public enum ClipboardPasteOutcome: Equatable, Sendable {
    case pasteRequested
    case copiedOnly(ClipboardPasteCopyOnlyReason)
    case copyFailed
    case cancelled
}

public enum ClipboardPasteNativeError: Error, Equatable, Sendable {
    case eventCreationFailed
}

/// The application instance and PID captured before payload hydration starts.
/// The coordinator revalidates both pieces at the last possible moment.
@MainActor
public struct ClipboardPasteTarget {
    public let application: NSRunningApplication
    public let processIdentifier: pid_t

    public init(application: NSRunningApplication, processIdentifier: pid_t) {
        self.application = application
        self.processIdentifier = processIdentifier
    }

    public static func capture(
        previousApplication: NSRunningApplication?,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> ClipboardPasteTarget? {
        guard let previousApplication,
              !previousApplication.isTerminated,
              previousApplication.processIdentifier > 0,
              previousApplication.processIdentifier != ownProcessIdentifier else {
            return nil
        }

        return ClipboardPasteTarget(
            application: previousApplication,
            processIdentifier: previousApplication.processIdentifier
        )
    }
}

/// The small native seam used by the coordinator.  The internal target closures
/// let unit tests model termination and foreground races without controlling an
/// actual user application.
@MainActor
public struct ClipboardPasteNativeBoundary {
    public var accessibilityTrusted: (_ prompt: Bool) -> Bool
    public var postEventAccess: () -> Bool
    public var frontmostApplication: () -> NSRunningApplication?
    public var postCommandV: (_ processIdentifier: pid_t) throws -> Void
    public var sleep: (_ duration: Duration) async throws -> Void

    internal var targetIsUsable: (ClipboardPasteTarget) -> Bool
    internal var frontmostMatchesTarget: (ClipboardPasteTarget, NSRunningApplication?) -> Bool
    internal var frontmostIsUnrelated: (ClipboardPasteTarget, NSRunningApplication?) -> Bool

    public init(
        accessibilityTrusted: @escaping (_ prompt: Bool) -> Bool,
        postEventAccess: @escaping () -> Bool,
        frontmostApplication: @escaping () -> NSRunningApplication?,
        postCommandV: @escaping (_ processIdentifier: pid_t) throws -> Void,
        sleep: @escaping (_ duration: Duration) async throws -> Void
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.postEventAccess = postEventAccess
        self.frontmostApplication = frontmostApplication
        self.postCommandV = postCommandV
        self.sleep = sleep
        self.targetIsUsable = { target in
            target.processIdentifier > 0
                && target.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && !target.application.isTerminated
                && target.application.processIdentifier == target.processIdentifier
        }
        self.frontmostMatchesTarget = { target, frontmost in
            guard let frontmost else {
                return false
            }
            return frontmost.isEqual(target.application)
                && frontmost.processIdentifier == target.processIdentifier
                && target.application.isActive
                && !target.application.isTerminated
        }
        self.frontmostIsUnrelated = { target, frontmost in
            guard let frontmost,
                  !frontmost.isTerminated,
                  frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return false
            }
            return !frontmost.isEqual(target.application)
                || frontmost.processIdentifier != target.processIdentifier
        }
    }

    public static let live = ClipboardPasteNativeBoundary(
        accessibilityTrusted: { prompt in
            if prompt {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                let options = [promptKey: true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            }
            return AXIsProcessTrustedWithOptions(nil)
        },
        postEventAccess: {
            CGPreflightPostEventAccess()
        },
        frontmostApplication: {
            NSWorkspace.shared.frontmostApplication
        },
        postCommandV: { processIdentifier in
            guard let commandDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 55,
                keyDown: true
            ),
            let pasteDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 9,
                keyDown: true
            ),
            let pasteUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 9,
                keyDown: false
            ),
            let commandUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 55,
                keyDown: false
            ) else {
                throw ClipboardPasteNativeError.eventCreationFailed
            }

            pasteDown.flags = .maskCommand
            pasteUp.flags = .maskCommand
            commandDown.postToPid(processIdentifier)
            pasteDown.postToPid(processIdentifier)
            pasteUp.postToPid(processIdentifier)
            commandUp.postToPid(processIdentifier)
        },
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )
}

/// Coordinates one copy/paste action and owns the cancellation distinction
/// between an intended panel close and a user dismissal.
@MainActor
public final class ClipboardPasteCoordinator {
    private enum FocusWaitResult {
        case focused
        case targetChanged
        case timedOut
        case cancelled
    }

    private let copyItem: @MainActor (UUID) async -> ClipboardRestoreReceipt?
    private let restoreStillCurrent: @MainActor (ClipboardRestoreReceipt) -> Bool
    private let closePanel: @MainActor () -> Void
    private let native: ClipboardPasteNativeBoundary
    private let permittedTarget: @MainActor (ClipboardPasteTarget) -> Bool
    private let onOutcome: @MainActor (ClipboardPasteOutcome) -> Void
    private let focusTimeout: Duration
    private let focusPollInterval: Duration

    private var actionTask: Task<Void, Never>?
    private var generation = 0
    private var expectedCloseGeneration: Int?
    private var isShutDown = false

    public init(
        copyItem: @escaping @MainActor (UUID) async -> ClipboardRestoreReceipt?,
        restoreStillCurrent: @escaping @MainActor (ClipboardRestoreReceipt) -> Bool,
        closePanel: @escaping @MainActor () -> Void,
        native: ClipboardPasteNativeBoundary = .live,
        permittedTarget: @escaping @MainActor (ClipboardPasteTarget) -> Bool = { _ in true },
        onOutcome: @escaping @MainActor (ClipboardPasteOutcome) -> Void,
        focusTimeout: Duration = .milliseconds(300),
        focusPollInterval: Duration = .milliseconds(20)
    ) {
        self.copyItem = copyItem
        self.restoreStillCurrent = restoreStillCurrent
        self.closePanel = closePanel
        self.native = native
        self.permittedTarget = permittedTarget
        self.onOutcome = onOutcome
        self.focusTimeout = max(.zero, focusTimeout)
        self.focusPollInterval = max(.zero, focusPollInterval)
    }

    /// Whether both native permission checks currently allow automatic paste.
    /// This property never prompts for access.
    public var canAutomaticallyPaste: Bool {
        let accessibility = native.accessibilityTrusted(false)
        let postAccess = native.postEventAccess()
        return accessibility && postAccess
    }

    /// Requests the Accessibility prompt for an explicit user-facing enable
    /// action.  It intentionally does not request event-post access implicitly.
    public func requestAccessibilityAccess() {
        _ = native.accessibilityTrusted(true)
    }

    /// Starts a new generation synchronously, cancelling any older action before
    /// its asynchronous copy result can affect the current operation.
    public func begin(
        itemID: UUID,
        intent: ClipboardPasteIntent,
        target: ClipboardPasteTarget?
    ) {
        guard !isShutDown else {
            return
        }

        invalidateCurrentAction()
        let actionGeneration = generation
        actionTask = Task { @MainActor [weak self] in
            await self?.run(
                itemID: itemID,
                intent: intent,
                target: target,
                generation: actionGeneration
            )
        }
    }

    /// Cancels the current action and synchronously reports cancellation for the
    /// current generation. Any later completion from the cancelled task is stale.
    public func cancel() {
        invalidateCurrentAction(notifyCancelled: true)
    }

    /// A newly opened panel supersedes a pending action and clears an expected
    /// close marker left by a prior panel instance.
    public func panelDidOpen() {
        guard actionTask != nil || expectedCloseGeneration != nil else {
            return
        }
        invalidateCurrentAction(notifyCancelled: true)
    }

    /// A close generated by the coordinator is allowed to continue toward paste.
    /// Any other close is user dismissal and cancels the pending action.
    public func panelDidClose() {
        if expectedCloseGeneration == generation {
            expectedCloseGeneration = nil
            return
        }
        invalidateCurrentAction(notifyCancelled: true)
    }

    /// Invalidates all pending work during app shutdown.
    public func shutdown() {
        guard !isShutDown else {
            return
        }
        isShutDown = true
        invalidateCurrentAction(notifyCancelled: true)
    }

    private func run(
        itemID: UUID,
        intent: ClipboardPasteIntent,
        target: ClipboardPasteTarget?,
        generation actionGeneration: Int
    ) async {
        guard isCurrent(actionGeneration) else {
            return
        }

        guard let receipt = await copyItem(itemID) else {
            finish(.copyFailed, generation: actionGeneration)
            return
        }

        guard isCurrent(actionGeneration), !Task.isCancelled else {
            return
        }

        if intent == .copyOnly {
            closeForExpectedAction(generation: actionGeneration)
            finish(.copiedOnly(.explicitCopy), generation: actionGeneration)
            return
        }

        guard let target else {
            closeForExpectedAction(generation: actionGeneration)
            finish(.copiedOnly(.noTarget), generation: actionGeneration)
            return
        }

        guard permittedTarget(target) else {
            closeForExpectedAction(generation: actionGeneration)
            finish(.copiedOnly(.targetNotPermitted), generation: actionGeneration)
            return
        }

        guard native.targetIsUsable(target) else {
            closeForExpectedAction(generation: actionGeneration)
            finish(.copiedOnly(.targetChanged), generation: actionGeneration)
            return
        }

        // Prompt only after an explicit paste choice and after the item is safely
        // copied.  The no-prompt check is repeated immediately before posting.
        guard native.accessibilityTrusted(true) else {
            closeForExpectedAction(generation: actionGeneration)
            finish(.copiedOnly(.permissionUnavailable), generation: actionGeneration)
            return
        }

        closeForExpectedAction(generation: actionGeneration)
        switch await waitForFocus(target, generation: actionGeneration) {
        case .cancelled:
            return
        case .targetChanged:
            finish(.copiedOnly(.targetChanged), generation: actionGeneration)
            return
        case .timedOut:
            finish(.copiedOnly(.focusTimeout), generation: actionGeneration)
            return
        case .focused:
            break
        }

        guard isCurrent(actionGeneration), !Task.isCancelled else {
            return
        }

        guard restoreStillCurrent(receipt) else {
            finish(.copiedOnly(.clipboardReplaced), generation: actionGeneration)
            return
        }

        let frontmost = native.frontmostApplication()
        guard native.targetIsUsable(target),
              native.frontmostMatchesTarget(target, frontmost) else {
            finish(.copiedOnly(.targetChanged), generation: actionGeneration)
            return
        }

        // Keep the permission checks adjacent to the PID-targeted post. No await
        // or focus retry occurs after them, so a stale result cannot turn into
        // synthetic input after the final clipboard/target validation.
        guard native.accessibilityTrusted(false) else {
            finish(.copiedOnly(.permissionUnavailable), generation: actionGeneration)
            return
        }

        guard native.postEventAccess() else {
            finish(.copiedOnly(.nativePostUnavailable), generation: actionGeneration)
            return
        }

        guard restoreStillCurrent(receipt) else {
            finish(.copiedOnly(.clipboardReplaced), generation: actionGeneration)
            return
        }

        do {
            try native.postCommandV(target.processIdentifier)
        } catch {
            finish(.copiedOnly(.nativePostUnavailable), generation: actionGeneration)
            return
        }

        finish(.pasteRequested, generation: actionGeneration)
    }

    private func waitForFocus(
        _ target: ClipboardPasteTarget,
        generation actionGeneration: Int
    ) async -> FocusWaitResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: focusTimeout)

        while true {
            guard isCurrent(actionGeneration), !Task.isCancelled else {
                return .cancelled
            }
            guard native.targetIsUsable(target) else {
                return .targetChanged
            }

            let frontmost = native.frontmostApplication()
            if native.frontmostMatchesTarget(target, frontmost) {
                return .focused
            }
            if native.frontmostIsUnrelated(target, frontmost) {
                return .targetChanged
            }
            if clock.now >= deadline {
                return .timedOut
            }

            do {
                try await native.sleep(focusPollInterval)
            } catch {
                return Task.isCancelled ? .cancelled : .timedOut
            }
        }
    }

    private func closeForExpectedAction(generation actionGeneration: Int) {
        guard isCurrent(actionGeneration) else {
            return
        }
        expectedCloseGeneration = actionGeneration
        closePanel()
    }

    private func finish(_ outcome: ClipboardPasteOutcome, generation actionGeneration: Int) {
        guard isCurrent(actionGeneration) else {
            return
        }
        actionTask = nil
        expectedCloseGeneration = nil
        onOutcome(outcome)
    }

    private func isCurrent(_ actionGeneration: Int) -> Bool {
        !isShutDown && generation == actionGeneration
    }

    private func invalidateCurrentAction(notifyCancelled: Bool = false) {
        let hadCurrentAction = actionTask != nil || expectedCloseGeneration != nil
        generation &+= 1
        actionTask?.cancel()
        actionTask = nil
        expectedCloseGeneration = nil
        if notifyCancelled, hadCurrentAction {
            onOutcome(.cancelled)
        }
    }
}
