import Foundation

public enum ClipboardMonitorPollResult: Equatable, Sendable {
    case startupBaseline(changeCount: Int)
    case unchanged(changeCount: Int)
    case selfWriteSuppressed(changeCount: Int)
    case captured(ClipboardCaptureCandidate)
    case paused(changeCount: Int)
    case sleeping(changeCount: Int)
    case skipped(PasteboardSkipReason)
}

/// A stable pasteboard snapshot accepted in poll order. The generation changes
/// when recording policy or lifecycle state changes, allowing the async history
/// worker to discard stale, not-yet-persisted clipboard data.
public struct ClipboardCaptureCandidate: Equatable, Sendable {
    public let snapshot: PasteboardSnapshot
    public let generation: UInt64
    public let capturedAt: Date

    public init(snapshot: PasteboardSnapshot, generation: UInt64, capturedAt: Date = Date()) {
        self.snapshot = snapshot
        self.generation = generation
        self.capturedAt = capturedAt
    }
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
    private var retention: ClipboardHistoryRetention
    private var timer: Timer?
    private var observedChangeCount: Int?
    private var unstableChangeCount: Int?
    private var retryRequested = false
    private var suppressedChangeCounts: Set<Int> = []
    private var excludedBundleIdentifiers: Set<String> = []
    private var recordingPaused = false
    private var isSleeping = false
    private var captureGeneration: UInt64 = 0

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
        now: @escaping () -> Date = { Date() },
        retention: ClipboardHistoryRetention = .default
    ) {
        self.pasteboard = pasteboard
        self.history = history
        self.pollInterval = max(0.05, pollInterval)
        self.now = now
        self.retention = retention
        super.init()
    }

    isolated deinit {
        timer?.invalidate()
    }

    public var isRunning: Bool {
        timer != nil
    }

    public var isRecordingPaused: Bool {
        recordingPaused
    }

    public var currentCaptureGeneration: UInt64 {
        captureGeneration
    }

    public var accessState: PasteboardAccessState {
        pasteboard.accessState
    }

    public func start() {
        guard timer == nil else {
            return
        }

        pasteboard.setExcludedBundleIdentifiers(excludedBundleIdentifiers)
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

    /// Applies recording pause without stopping the lightweight change-count timer.
    /// The current count becomes the new baseline, so paused writes are never caught
    /// up when recording resumes.
    public func setRecordingPaused(_ paused: Bool) {
        guard recordingPaused != paused else {
            return
        }
        recordingPaused = paused
        invalidatePendingCaptureGeneration()
        rebaseline()
    }

    /// Updates the boundary before the next capture. Pending candidates from the old
    /// policy are discarded so an exclusion change cannot persist stale private data.
    public func setExcludedBundleIdentifiers(_ identifiers: Set<String>) {
        guard excludedBundleIdentifiers != identifiers else {
            return
        }
        excludedBundleIdentifiers = identifiers
        pasteboard.setExcludedBundleIdentifiers(identifiers)
        invalidatePendingCaptureGeneration()
        rebaseline()
    }

    /// Called after a sleep/wake transition. Re-baselining avoids catching up writes
    /// made while the utility was asleep, including writes made while paused.
    public func handleSleep() {
        isSleeping = true
        invalidatePendingCaptureGeneration()
        rebaseline()
    }

    public func handleWake() {
        isSleeping = false
        invalidatePendingCaptureGeneration()
        rebaseline()
    }

    /// Keeps the transient metadata cache aligned with durable pin actions. The
    /// cache is only a fast, bounded monitor view; the repository remains canonical.
    func setPinned(_ pinned: Bool, for id: UUID, now: Date? = nil) {
        _ = history.setPinned(pinned, for: id)
        if let now {
            history.applyRetention(retention, now: now)
        }
    }

    /// Mirrors a durable recency update before applying retention, preserving the
    /// cache row's canonical identity and pin state.
    func markUsed(at date: Date, for id: UUID) {
        _ = history.markUsed(at: date, for: id)
    }

    /// Updates the cache policy after the durable repository has committed the
    /// same policy, pruning only metadata that the repository would remove.
    func setRetention(_ retention: ClipboardHistoryRetention, now: Date = Date()) {
        self.retention = retention
        history.applyRetention(retention, now: now)
    }

    /// Reapplies the current policy after a durable mutation such as a recency
    /// update that may have evicted other unpinned rows.
    func pruneRetention(now: Date = Date()) {
        history.applyRetention(retention, now: now)
    }

    /// Removes an item from the transient cache after its durable row is deleted.
    func removeCachedItem(id: UUID) {
        _ = history.remove(id: id)
    }

    /// Removes rows from the transient cache after a durable clear operation.
    func clearCachedItems(keepingPinned: Bool = false) {
        history.clear(keepingPinned: keepingPinned)
    }

    /// Inserts only metadata into the monitor cache after durable persistence has
    /// succeeded. The cache never retains the captured payload/blob bytes.
    public func recordPersisted(_ item: ClipboardItem, now: Date? = nil) {
        _ = history.record(item)
        if let now {
            history.applyRetention(retention, now: now)
        }
    }

    /// The app lifecycle uses the timer, while tests and callers that need an immediate
    /// refresh can drive the same state machine synchronously.
    @discardableResult
    public func pollNow() -> ClipboardMonitorPollResult {
        let currentChangeCount = pasteboard.changeCount

        if isSleeping {
            observedChangeCount = currentChangeCount
            unstableChangeCount = nil
            retryRequested = false
            return publish(.sleeping(changeCount: currentChangeCount))
        }

        if recordingPaused {
            observedChangeCount = currentChangeCount
            unstableChangeCount = nil
            retryRequested = false
            return publish(.paused(changeCount: currentChangeCount))
        }

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
            let candidate = ClipboardCaptureCandidate(
                snapshot: snapshot,
                generation: captureGeneration,
                capturedAt: now()
            )
            return publish(.captured(candidate))

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

    private func invalidatePendingCaptureGeneration() {
        captureGeneration &+= 1
    }

    private func rebaseline() {
        observedChangeCount = pasteboard.changeCount
        unstableChangeCount = nil
        retryRequested = false
        suppressedChangeCounts.removeAll(keepingCapacity: true)
    }
}
