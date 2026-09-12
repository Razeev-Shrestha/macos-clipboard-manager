import AppKit
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

    /// Internal visibility is intentional: the monitor cache is an implementation
    /// detail and is exposed only to core tests that verify cache invalidation.
    var transientCacheItems: [ClipboardItem] {
        monitor.history.items
    }

    private let monitor: NSPasteboardMonitor
    private let repository: ClipboardHistoryRepository
    private let now: () -> Date
    private var mutationTail: Task<Bool, Never>?
    private var pendingCaptureTasks: [UUID: (generation: UInt64, task: Task<Bool, Never>)] = [:]
    private var searchTask: Task<Void, Never>?
    private var queryGeneration = 0
    private var hasOpenedRepository = false
    private var isStarting = false
    private var isShuttingDown = false
    private var hasStorageFailure = false

    public convenience init(
        pasteboard: any ClipboardPasteboard,
        repository: ClipboardHistoryRepository,
        retention: ClipboardHistoryRetention = .default
    ) {
        self.init(
            pasteboard: pasteboard,
            repository: repository,
            retention: retention,
            now: { Date() }
        )
    }

    init(
        pasteboard: any ClipboardPasteboard,
        repository: ClipboardHistoryRepository,
        retention: ClipboardHistoryRetention,
        now: @escaping () -> Date
    ) {
        self.repository = repository
        self.now = now
        monitor = NSPasteboardMonitor(
            pasteboard: pasteboard,
            now: now,
            retention: retention
        )
        monitor.onPollResult = { [weak self] result, _, accessState in
            guard let self else {
                return
            }

            if self.accessState != accessState {
                self.accessState = accessState
            }
            if case .captured(let candidate) = result {
                self.enqueueCapture(candidate)
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
            repository: ClipboardHistoryRepository(databaseURL: databaseURL, retention: retention),
            retention: retention
        )
    }

    deinit {
        mutationTail?.cancel()
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

    public var isRecordingPaused: Bool {
        monitor.isRecordingPaused
    }

    public func setRecordingPaused(_ paused: Bool) {
        monitor.setRecordingPaused(paused)
        cancelStaleCaptureTasks()
    }

    public func setExcludedBundleIdentifiers(_ identifiers: Set<String>) {
        monitor.setExcludedBundleIdentifiers(identifiers)
        cancelStaleCaptureTasks()
    }

    public func handleWake() {
        monitor.handleWake()
        cancelStaleCaptureTasks()
    }

    public func handleSleep() {
        monitor.handleSleep()
        cancelStaleCaptureTasks()
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

        _ = await mutationTail?.value
        guard !isShuttingDown, !hasStorageFailure, !Task.isCancelled else {
            return nil
        }

        let item: ClipboardItem?
        do {
            item = try await repository.item(id: id)
        } catch let error as ClipboardHistoryRepositoryError {
            if error != .payloadUnavailable {
                recordStorageFailure()
            }
            return nil
        } catch {
            recordStorageFailure()
            return nil
        }

        guard !isShuttingDown, !hasStorageFailure, !Task.isCancelled,
              let item, item.payload != nil,
              let receipt = monitor.restoreReceipt(item) else {
            return nil
        }

        let actionDate = now()
        _ = await enqueueMutation({ repository in
            try await repository.markUsed(id: id, at: actionDate)
        }, onSuccess: { [weak self] in
            self?.monitor.markUsed(at: actionDate, for: id)
            self?.monitor.pruneRetention(now: actionDate)
        })
        return receipt
    }

    /// Returns whether the pasteboard still contains the exact verified write
    /// produced by `copyItemWithReceipt`.
    public func isRestoreCurrent(_ receipt: ClipboardRestoreReceipt) -> Bool {
        monitor.isCurrent(receipt)
    }

    /// Hydrates one selected row for an expanded preview. Metadata rows remain
    /// available when the payload/blob is unavailable, and item-local errors are
    /// intentionally returned to the caller instead of poisoning storage state.
    public func loadItem(id: UUID) async throws -> ClipboardItem? {
        guard hasOpenedRepository, storageState == .ready, !isShuttingDown else {
            return nil
        }
        _ = await mutationTail?.value
        try Task.checkCancellation()
        let item = try await repository.item(id: id)
        try Task.checkCancellation()
        return item
    }

    @discardableResult
    public func setPinned(_ pinned: Bool, for id: UUID) async -> Bool {
        let actionDate = now()
        return await enqueueMutation({ repository in
            let item = try await repository.setPinned(pinned, for: id, now: actionDate)
            // The repository may remove an aged row immediately after a
            // successful unpin, so a nil returned metadata row still means the
            // requested unpin transaction completed.
            return item != nil || !pinned
        }, onSuccess: { [weak self] in
            self?.monitor.setPinned(pinned, for: id, now: actionDate)
        })
    }

    @discardableResult
    public func deleteItem(id: UUID) async -> Bool {
        return await enqueueMutation({ repository in
            try await repository.delete(id: id)
            return true
        }, onSuccess: { [weak self] in
            self?.monitor.removeCachedItem(id: id)
        })
    }

    @discardableResult
    public func clearHistory(keepingPinned: Bool = false) async -> Bool {
        return await enqueueMutation({ repository in
            try await repository.clear(keepingPinned: keepingPinned)
            return true
        }, onSuccess: { [weak self] in
            self?.monitor.clearCachedItems(keepingPinned: keepingPinned)
        })
    }

    @discardableResult
    public func updateRetention(
        _ retention: ClipboardRetentionSettings,
        now: Date = Date()
    ) async -> Bool {
        guard retention.isValid else {
            return false
        }
        let policy = ClipboardHistoryRetention(
            maximumUnpinnedItems: retention.maximumUnpinnedItems,
            maximumUnpinnedAge: retention.maximumUnpinnedAge
        )
        return await enqueueMutation({ repository in
            try await repository.updateRetention(policy, now: now)
            return true
        }, onSuccess: { [weak self] in
            self?.monitor.setRetention(policy, now: now)
        })
    }

    /// Waits for accepted captures and then refreshes the currently selected query.
    /// This is useful for deterministic tests and for future explicit refresh UI.
    public func flush() async {
        let pendingMutation = mutationTail
        _ = await pendingMutation?.value
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
        let pendingMutation = mutationTail
        _ = await pendingMutation?.value

        searchTask?.cancel()
        let pendingSearch = searchTask
        await pendingSearch?.value

        if hasOpenedRepository || isStarting {
            await repository.close()
        }
        hasOpenedRepository = false
        storageState = .inactive
    }

    private func enqueueCapture(_ candidate: ClipboardCaptureCandidate) {
        guard hasOpenedRepository, !isShuttingDown, !hasStorageFailure else {
            return
        }

        // Assign this task to the one mutation tail before any detached work is
        // started. Later delete/clear actions therefore wait for this accepted
        // candidate and cannot be followed by a late capture resurrection.
        let previousMutation = mutationTail
        let repository = repository
        let monitor = monitor
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.finishCaptureTask(token)
            }
            do {
                _ = await previousMutation?.value
                try Task.checkCancellation()
                let item = await Self.processCapture(
                    candidate.snapshot.capture,
                    capturedAt: candidate.capturedAt
                )
                try Task.checkCancellation()
                guard let self,
                      self.monitor.currentCaptureGeneration == candidate.generation
                else {
                    return false
                }

                let stored = try await repository.record(item, now: candidate.capturedAt)
                // A policy change may cancel this task while the repository actor
                // is writing. The repository performs its own pre-write/commit
                // checks; this final check prevents a canceled completion from
                // repopulating the transient cache.
                try Task.checkCancellation()
                monitor.recordPersisted(stored, now: candidate.capturedAt)
                self.didPersistWrite()
                return true
            } catch is CancellationError {
                // Policy invalidation is an expected capture discard and must not
                // turn the controller's durable storage state into .failed.
                return false
            } catch {
                self?.didFailStorageOperation()
                return false
            }
        }
        pendingCaptureTasks[token] = (generation: candidate.generation, task: task)
        mutationTail = task
    }

    private func cancelStaleCaptureTasks() {
        let currentGeneration = monitor.currentCaptureGeneration
        for pending in pendingCaptureTasks.values where pending.generation != currentGeneration {
            pending.task.cancel()
        }
    }

    private func finishCaptureTask(_ token: UUID) {
        pendingCaptureTasks.removeValue(forKey: token)
    }

    private func enqueueMutation(
        _ operation: @escaping @Sendable (ClipboardHistoryRepository) async throws -> Bool,
        onSuccess: @escaping @MainActor @Sendable () -> Void = {}
    ) async -> Bool {
        guard hasOpenedRepository, !isShuttingDown, !hasStorageFailure else {
            return false
        }

        let previousMutation = mutationTail
        let repository = repository
        let task = Task { @MainActor [weak self] in
            _ = await previousMutation?.value
            guard !Task.isCancelled else {
                return false
            }
            do {
                let changed = try await operation(repository)
                if changed {
                    onSuccess()
                }
                self?.didPersistWrite()
                return changed
            } catch {
                self?.didFailStorageOperation()
                return false
            }
        }
        mutationTail = task
        return await task.value
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

    private nonisolated static func processCapture(
        _ capture: ClipboardCapture,
        capturedAt: Date
    ) async -> ClipboardItem {
        await Task.detached(priority: .utility) {
            let enrichedCapture = enrichCapture(capture)
            return ClipboardItem(
                capture: enrichedCapture,
                createdAt: capturedAt,
                lastUsedAt: capturedAt
            )
        }.value
    }

    private nonisolated static func enrichCapture(_ capture: ClipboardCapture) -> ClipboardCapture {
        var payload = capture.payload
        var searchableText = capture.searchableText

        if let items = payload.items {
            var enrichedItems = [ClipboardPayloadItem]()
            var derivedSearchableParts = [String]()
            for item in items {
                let itemText = item.plainText ?? rtfText(in: item)
                if let itemText, !itemText.isEmpty {
                    derivedSearchableParts.append(itemText)
                } else if let itemURL = item.url {
                    // File pasteboard items should remain searchable by filename;
                    // the boundary already uses this same URL-derived component.
                    let searchableURLComponent = itemURL.lastPathComponent.isEmpty
                        ? itemURL.absoluteString
                        : itemURL.lastPathComponent
                    derivedSearchableParts.append(searchableURLComponent)
                }
                enrichedItems.append(
                    ClipboardPayloadItem(
                        primaryTypeIdentifier: item.primaryTypeIdentifier,
                        representations: item.representations,
                        availableTypeIdentifiers: item.availableTypeIdentifiers,
                        plainText: item.plainText ?? itemText,
                        url: item.url
                    )
                )
            }
            searchableText = mergeSearchableText(
                existing: searchableText,
                additions: derivedSearchableParts
            )
            payload = ClipboardPayload(
                primaryTypeIdentifier: payload.primaryTypeIdentifier,
                representations: payload.representations,
                availableTypeIdentifiers: payload.availableTypeIdentifiers,
                plainText: payload.plainText,
                url: payload.url,
                items: enrichedItems
            )
        } else if payload.plainText == nil,
                  let plainText = rtfText(in: payload)
        {
            searchableText = mergeSearchableText(existing: searchableText, additions: [plainText])
            payload = ClipboardPayload(
                primaryTypeIdentifier: payload.primaryTypeIdentifier,
                representations: payload.representations,
                availableTypeIdentifiers: payload.availableTypeIdentifiers,
                plainText: plainText,
                url: payload.url
            )
        }

        let primaryType: ClipboardPrimaryType
        switch capture.primaryType {
        case .text, .code:
            if let searchableText, let url = URL(string: searchableText), url.scheme != nil {
                primaryType = .url
            } else if ClipboardTextClassifier.isLikelyCode(searchableText ?? "") {
                primaryType = .code
            } else {
                primaryType = .text
            }
        default:
            primaryType = capture.primaryType
        }

        return ClipboardCapture(
            payload: payload,
            primaryType: primaryType,
            searchableText: searchableText,
            source: capture.source
        )
    }

    private nonisolated static func mergeSearchableText(
        existing: String?,
        additions: [String]
    ) -> String? {
        let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var merged = existing
        for addition in additions {
            let trimmed = addition.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !merged.contains(trimmed) else {
                continue
            }
            if !merged.isEmpty {
                merged.append(" ")
            }
            merged.append(trimmed)
        }
        return merged.isEmpty ? nil : merged
    }

    private nonisolated static func rtfText(in payload: ClipboardPayload) -> String? {
        let data = payload.representations.first {
            $0.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue
        }?.data
        guard let data else {
            return nil
        }
        return rtfString(data)
    }

    private nonisolated static func rtfText(in item: ClipboardPayloadItem) -> String? {
        let data = item.representations.first {
            $0.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue
        }?.data
        guard let data else {
            return nil
        }
        return rtfString(data)
    }

    private nonisolated static func rtfString(_ data: Data) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        guard let attributed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else {
            return nil
        }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
