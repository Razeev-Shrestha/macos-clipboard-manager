import Foundation

public enum ClipboardMonitorPollResult: Equatable, Sendable {
    case startupBaseline(changeCount: Int)
    case unchanged(changeCount: Int)
    case selfWriteSuppressed(changeCount: Int)
    case recorded(ClipboardHistoryUpdate)
    case skipped(PasteboardSkipReason)
}

/// The exact pasteboard change count verified by an internal restore.  The
/// coordinator uses this receipt to reject a paste when another process has
/// replaced the clipboard while focus was being restored.
public struct ClipboardRestoreReceipt: Equatable, Sendable {
    public let changeCount: Int

    public init(changeCount: Int) {
        self.changeCount = changeCount
    }
}

/// Main-actor change-count polling and capture coordinator.  Only a changed count
/// causes a pasteboard read; the timer itself does no payload work on unchanged ticks.
@MainActor
public final class NSPasteboardMonitor: NSObject {
    public static let defaultPollInterval: TimeInterval = 0.4

    private let pasteboard: any ClipboardPasteboard
    private let now: () -> Date
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var observedChangeCount: Int?
    private var unstableChangeCount: Int?
    private var retryRequested = false
    private var suppressedChangeCounts: Set<Int> = []

    public private(set) var history: InMemoryClipboardHistory
    public var onPollResult: (@MainActor (
        ClipboardMonitorPollResult,
        [ClipboardItem],
        PasteboardAccessState
    ) -> Void)?

    public init(
        pasteboard: any ClipboardPasteboard,
        history: InMemoryClipboardHistory = InMemoryClipboardHistory(),
        pollInterval: TimeInterval = NSPasteboardMonitor.defaultPollInterval,
        now: @escaping () -> Date = { Date() }
    ) {
        self.pasteboard = pasteboard
        self.history = history
        self.pollInterval = max(0.05, pollInterval)
        self.now = now
        super.init()
    }

    isolated deinit {
        timer?.invalidate()
    }

    public var isRunning: Bool {
        timer != nil
    }

    public var accessState: PasteboardAccessState {
        pasteboard.accessState
    }

    public func start() {
        guard timer == nil else {
            return
        }

        observedChangeCount = pasteboard.changeCount
        unstableChangeCount = nil
        suppressedChangeCounts.removeAll(keepingCapacity: true)

        let newTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = self?.pollNow()
            }
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The app lifecycle uses the timer, while tests and callers that need an immediate
    /// refresh can drive the same state machine synchronously.
    @discardableResult
    public func pollNow() -> ClipboardMonitorPollResult {
        let currentChangeCount = pasteboard.changeCount
        let forcedRetry = retryRequested && retryRequestedForCurrentCount(currentChangeCount)
        retryRequested = false

        if observedChangeCount == nil {
            observedChangeCount = currentChangeCount
            if !forcedRetry {
                return publish(.startupBaseline(changeCount: currentChangeCount))
            }
        }

        if suppressedChangeCounts.remove(currentChangeCount) != nil {
            observedChangeCount = currentChangeCount
            unstableChangeCount = nil
            return publish(.selfWriteSuppressed(changeCount: currentChangeCount))
        }

        let retryingUnstableRead = unstableChangeCount == currentChangeCount
        if observedChangeCount == currentChangeCount, !retryingUnstableRead, !forcedRetry {
            return publish(.unchanged(changeCount: currentChangeCount))
        }

        let readResult = pasteboard.readSnapshotIfStable(expectedChangeCount: currentChangeCount)
        observedChangeCount = currentChangeCount

        switch readResult {
        case .snapshot(let snapshot):
            guard snapshot.changeCount == currentChangeCount else {
                unstableChangeCount = currentChangeCount
                return publish(.skipped(.changedDuringRead))
            }

            unstableChangeCount = nil
            let captureDate = now()
            let item = ClipboardItem(
                capture: snapshot.capture,
                createdAt: captureDate,
                lastUsedAt: captureDate
            )
            return publish(.recorded(history.record(item)))

        case .skipped(.changedDuringRead):
            if unstableChangeCount == currentChangeCount {
                unstableChangeCount = nil
            } else {
                unstableChangeCount = currentChangeCount
            }
            return publish(.skipped(.changedDuringRead))

        case .skipped(let reason):
            unstableChangeCount = nil
            return publish(.skipped(reason))
        }
    }

    /// Put a saved item back on the pasteboard and remember only the verified write
    /// change count.  A write that races another process is not suppressed.
    @discardableResult
    public func restore(_ item: ClipboardItem) -> Bool {
        restoreReceipt(item) != nil
    }

    /// Restores a saved item and returns the exact verified internal-write count.
    /// The receipt contains no payload and is safe to retain across an async focus
    /// handoff.
    @discardableResult
    public func restoreReceipt(_ item: ClipboardItem) -> ClipboardRestoreReceipt? {
        guard let payload = item.payload else {
            return nil
        }
        return restoreReceipt(payload)
    }

    @discardableResult
    public func restore(_ payload: ClipboardPayload) -> Bool {
        restoreReceipt(payload) != nil
    }

    /// Restores a payload and returns the exact verified internal-write count.
    @discardableResult
    public func restoreReceipt(_ payload: ClipboardPayload) -> ClipboardRestoreReceipt? {
        switch pasteboard.write(payload: payload) {
        case .written(let changeCount):
            guard pasteboard.changeCount == changeCount else {
                return nil
            }
            insertSuppressedChangeCount(changeCount)
            observedChangeCount = changeCount
            unstableChangeCount = nil
            return ClipboardRestoreReceipt(changeCount: changeCount)
        case .failed, .changedDuringWrite:
            return nil
        }
    }

    /// Checks only the verified write count.  It deliberately does not read any
    /// pasteboard representation, so a replacement cannot be mistaken for the
    /// item that was restored earlier.
    public func isCurrent(_ receipt: ClipboardRestoreReceipt) -> Bool {
        pasteboard.changeCount == receipt.changeCount
    }

    /// Clear the read baseline after the user changes pasteboard access in System
    /// Settings, allowing the current count to be retried once.
    public func retryCurrentChange() {
        retryRequested = true
        unstableChangeCount = nil
    }

    private func retryRequestedForCurrentCount(_ currentChangeCount: Int) -> Bool {
        retryRequested && (observedChangeCount == currentChangeCount || observedChangeCount == nil)
    }

    private func publish(_ result: ClipboardMonitorPollResult) -> ClipboardMonitorPollResult {
        onPollResult?(result, history.items, accessState)
        return result
    }

    private func insertSuppressedChangeCount(_ changeCount: Int) {
        // A small cap prevents an unusual burst of internal writes while stopped from
        // becoming an unbounded collection.  Normal writes are consumed on the next tick.
        suppressedChangeCounts.insert(changeCount)
        while suppressedChangeCounts.count > 32 {
            guard let oldestStoredCount = suppressedChangeCounts.first else {
                break
            }
            suppressedChangeCounts.remove(oldestStoredCount)
        }
    }
}
