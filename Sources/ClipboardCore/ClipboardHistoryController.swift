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

/// Connects the main-actor pasteboard monitor to persistent history without making
/// SwiftUI render from the monitor's transient in-memory cache.
@MainActor
public final class ClipboardHistoryController: ObservableObject {
    @Published public private(set) var items: [ClipboardItem] = []
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
                self?.didPersistCapture()
            } catch {
                self?.didFailStorageOperation()
            }
        }
    }

    private func didPersistCapture() {
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
                self?.apply(rows, for: generation)
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
            apply(rows, for: generation)
        } catch {
            didFailQuery(for: generation)
        }
    }

    private func apply(_ rows: [ClipboardItem], for generation: Int) {
        guard generation == queryGeneration, !isShuttingDown else {
            return
        }
        items = rows
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
