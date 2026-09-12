import Combine
import Foundation

/// The lifecycle state for persistent history.  Error details intentionally remain
/// private because a database path can reveal user-specific information.
public enum ClipboardHistoryStorageState: Equatable, Sendable {
    case inactive
    case opening
    case ready
    case failed
}

/// One accepted history query result. The query and filter are captured with its
/// metadata rows so UI consumers never infer provenance from mutable controls.
public struct ClipboardHistoryResults: Equatable, Sendable {
    public let items: [ClipboardItem]
    public let query: String
    public let filter: ClipboardHistoryFilter

    public init(items: [ClipboardItem], query: String, filter: ClipboardHistoryFilter) {
        self.items = items
        self.query = query
        self.filter = filter
    }
}

/// Connects the main-actor pasteboard monitor to persistent history without making
/// SwiftUI render from the monitor's transient in-memory cache.
@MainActor
public final class ClipboardHistoryController: ObservableObject {
    @Published public private(set) var results = ClipboardHistoryResults(
        items: [],
        query: "",
        filter: .all
    )
    @Published public private(set) var accessState: PasteboardAccessState = .unknown
    @Published public private(set) var storageState: ClipboardHistoryStorageState = .inactive
    @Published public var query = "" {
        didSet {
            scheduleReload()
        }
    }
    @Published public var filter: ClipboardHistoryFilter = .all {
        didSet {
            scheduleReload()
        }
    }

    /// Metadata-only history rows from the last accepted query result.
    public var items: [ClipboardItem] {
        results.items
    }

    private let monitor: NSPasteboardMonitor
    private let repository: ClipboardHistoryRepository
    private var writeTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var queryGeneration = 0
    private var hasOpenedRepository = false
    private var isStarting = false
    private var isShuttingDown = false
    private var hasStorageFailure = false

    public init(
        pasteboard: any ClipboardPasteboard,
        repository: ClipboardHistoryRepository
    ) {
        self.repository = repository
        monitor = NSPasteboardMonitor(pasteboard: pasteboard)
        monitor.onPollResult = { [weak self] result, _, accessState in
            guard let self else {
                return
            }

            if self.accessState != accessState {
                self.accessState = accessState
            }
            if case .recorded(let update) = result {
                self.enqueuePersistence(of: update.item)
            }
        }
    }

    public convenience init(
        pasteboard: any ClipboardPasteboard,
        databaseURL: URL,
        retention: ClipboardHistoryRetention = .default
    ) {
        self.init(
            pasteboard: pasteboard,
            repository: ClipboardHistoryRepository(databaseURL: databaseURL, retention: retention)
        )
    }

    deinit {
        writeTask?.cancel()
        searchTask?.cancel()
    }

    /// Opens storage before monitoring, so every accepted capture has a durable
    /// destination.  Opening is asynchronous and performs no disk work in App init.
    public func start() async {
        guard !hasOpenedRepository, !isStarting, !isShuttingDown else {
            return
        }

        isStarting = true
        hasStorageFailure = false
        storageState = .opening
        do {
            try await repository.open()
            isStarting = false

            guard !isShuttingDown else {
                await repository.close()
                storageState = .inactive
                return
            }

            hasOpenedRepository = true
            storageState = .ready
            await reloadCurrentQuery()
            guard hasOpenedRepository, !isShuttingDown, !hasStorageFailure else {
                return
            }
            monitor.start()
        } catch {
            isStarting = false
            recordStorageFailure()
        }
    }

    /// Stops polling immediately.  Use `shutdown()` when the process is about to
    /// terminate so already accepted writes are flushed and the database is closed.
    public func stopMonitoring() {
        monitor.stop()
    }

    @discardableResult
    public func pollNow() -> ClipboardMonitorPollResult {
        monitor.pollNow()
    }

    /// Restores one persisted item without attempting focus restoration or a
    /// synthetic paste. The monitor owns the write so its self-write suppression
    /// remains in effect for the next poll.
    @discardableResult
    public func copyItem(id: UUID) async -> Bool {
        await copyItemWithReceipt(id: id) != nil
    }

    /// Restores one persisted item and returns the monitor's verified write
    /// receipt. The receipt is used by automatic paste to detect a clipboard
    /// replacement during focus restoration.
    @discardableResult
    public func copyItemWithReceipt(id: UUID) async -> ClipboardRestoreReceipt? {
        guard hasOpenedRepository, storageState == .ready, !isShuttingDown, !hasStorageFailure, !Task.isCancelled else {
            return nil
        }

        let item: ClipboardItem?
        do {
            item = try await repository.item(id: id)
        } catch {
            guard !isShuttingDown, !Task.isCancelled else {
                return nil
            }
            recordStorageFailure()
            return nil
        }

        guard !isShuttingDown, !hasStorageFailure, !Task.isCancelled,
              let item, item.payload != nil,
              let receipt = monitor.restoreReceipt(item) else {
            return nil
        }

        enqueueUsageUpdate(for: id, at: Date())
        return receipt
    }

    /// Returns whether the pasteboard still contains the exact verified write
    /// produced by `copyItemWithReceipt`.
    public func isRestoreCurrent(_ receipt: ClipboardRestoreReceipt) -> Bool {
        monitor.isCurrent(receipt)
    }

    /// Waits for accepted captures and then refreshes the currently selected query.
    /// This is useful for deterministic tests and for future explicit refresh UI.
    public func flush() async {
        let pendingWrite = writeTask
        await pendingWrite?.value
        guard hasOpenedRepository, !isShuttingDown, !hasStorageFailure else {
            return
        }
        await reloadCurrentQuery()
    }

    /// Stops the monitor, waits for every accepted capture write, cancels obsolete
    /// searches, and closes the repository.  Calling it more than once is safe.
    public func shutdown() async {
        guard !isShuttingDown else {
            return
        }

        isShuttingDown = true
        monitor.stop()
        let pendingWrite = writeTask
        await pendingWrite?.value

        searchTask?.cancel()
        let pendingSearch = searchTask
        await pendingSearch?.value

        if hasOpenedRepository || isStarting {
            await repository.close()
        }
        hasOpenedRepository = false
        storageState = .inactive
    }

    private func enqueuePersistence(of item: ClipboardItem) {
        guard hasOpenedRepository, !isShuttingDown, !hasStorageFailure else {
            return
        }

        let previousWrite = writeTask
        let repository = repository
        writeTask = Task { [weak self] in
            await previousWrite?.value
            guard !Task.isCancelled else {
                return
            }

            do {
                _ = try await repository.record(item)
                guard !Task.isCancelled else {
                    return
                }
                self?.didPersistWrite()
            } catch {
                self?.didFailStorageOperation()
            }
        }
    }

    private func enqueueUsageUpdate(for id: UUID, at date: Date) {
        let previousWrite = writeTask
        let repository = repository
        writeTask = Task { [weak self] in
            await previousWrite?.value
            do {
                _ = try await repository.markUsed(id: id, at: date)
                self?.didPersistWrite()
            } catch {
                self?.didFailStorageOperation()
            }
        }
    }

    private func didPersistWrite() {
        guard !isShuttingDown else {
            return
        }
        scheduleReload()
    }

    private func didFailStorageOperation() {
        guard !isShuttingDown else {
            return
        }
        recordStorageFailure()
    }

    private func scheduleReload() {
        guard hasOpenedRepository, !isShuttingDown, !hasStorageFailure else {
            return
        }

        queryGeneration += 1
        let generation = queryGeneration
        let query = query
        let filter = filter
        let repository = repository

        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                let rows = try await repository.history(query: query, filter: filter, limit: nil)
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(rows, query: query, filter: filter, for: generation)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.didFailQuery(for: generation)
            }
        }
    }

    private func reloadCurrentQuery() async {
        guard hasOpenedRepository, !isShuttingDown else {
            return
        }

        queryGeneration += 1
        let generation = queryGeneration
        let query = query
        let filter = filter
        do {
            let rows = try await repository.history(query: query, filter: filter, limit: nil)
            apply(rows, query: query, filter: filter, for: generation)
        } catch {
            didFailQuery(for: generation)
        }
    }

    private func apply(
        _ rows: [ClipboardItem],
        query: String,
        filter: ClipboardHistoryFilter,
        for generation: Int
    ) {
        guard generation == queryGeneration, !isShuttingDown else {
            return
        }
        results = ClipboardHistoryResults(items: rows, query: query, filter: filter)
    }

    private func didFailQuery(for generation: Int) {
        guard generation == queryGeneration, !isShuttingDown else {
            return
        }
        recordStorageFailure()
    }

    private func recordStorageFailure() {
        hasStorageFailure = true
        monitor.stop()
        storageState = .failed
    }
}
