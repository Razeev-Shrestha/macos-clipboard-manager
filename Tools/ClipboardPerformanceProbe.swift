import AppKit
import Darwin
import Foundation

private let syntheticBundleIdentifier = "com.example.ClipboardManager.gate-f-performance"

private enum ProbeArgumentError: Error {
    case unsupportedOption
}

private enum ProbePathSafetyError: Error {
    case unsafePath
    case databaseOpen
    case lsofUnavailable
}

private enum OwnedPathKind {
    case directory
    case regularFile
}

private struct ProbeArguments {
    let projectRoot: URL
    let storageDirectory: URL
    let databaseURL: URL
    let largeDatabaseURL: URL
    let pasteboardName: String
    let resetDataset: Bool

    init(arguments: [String]) throws {
        var resetDataset = false
        for argument in arguments.dropFirst() {
            guard argument == "--reset-dataset" else {
                throw ProbeArgumentError.unsupportedOption
            }
            resetDataset = true
        }

        // The probe is deliberately tied to the checked-out source tree. Keeping
        // these paths out of the CLI prevents an accidental reset of arbitrary
        // databases or an arbitrary pasteboard before validation completes.
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let storageDirectory = projectRoot.appendingPathComponent("build/GateFPerformance", isDirectory: true)

        self.projectRoot = projectRoot
        self.storageDirectory = storageDirectory
        self.databaseURL = storageDirectory.appendingPathComponent("history.sqlite")
        self.largeDatabaseURL = storageDirectory
            .appendingPathComponent("large", isDirectory: true)
            .appendingPathComponent("large-history.sqlite")
        self.pasteboardName = syntheticBundleIdentifier
        self.resetDataset = resetDataset
    }
}

private struct PollingMeasurement: Sendable {
    let samplesMilliseconds: [Double]
    let unchangedCount: Int
    let readCount: Int
    let accessState: PasteboardAccessState
}

private struct DatasetMeasurement: Sendable {
    let insertSamplesMilliseconds: [Double]
    let insertTotalMilliseconds: Double
    let querySamplesMilliseconds: [Double]
    let searchSamplesMilliseconds: [Double]
    let hydrationSamplesMilliseconds: [Double]
    let rowCount: Int
    let searchResultCount: Int
    let selectedHydrationByteSize: Int
}

private struct LargePayloadMeasurement: Sendable {
    let hashSamplesMilliseconds: [Double]
    let storeSamplesMilliseconds: [Double]
    let hydrationSamplesMilliseconds: [Double]
    let storedCount: Int
    let hydratedByteSize: Int
    let hydratedFromBlob: Bool
}

private struct TimingSummary {
    let count: Int
    let minimum: Double
    let median: Double
    let p95: Double
    let maximum: Double

    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        minimum = sorted.first ?? 0
        median = Self.percentile(sorted, fraction: 0.50)
        p95 = Self.percentile(sorted, fraction: 0.95)
        maximum = sorted.last ?? 0
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count - 1))))
        return sorted[index]
    }
}

@MainActor
private final class CountingPasteboard: ClipboardPasteboard {
    var changeCount = 1
    var accessState: PasteboardAccessState = .allowed
    private(set) var readCount = 0

    func readSnapshotIfStable(expectedChangeCount: Int) -> PasteboardReadResult {
        readCount += 1
        return .skipped(.empty)
    }

    func write(payload: ClipboardPayload) -> PasteboardWriteResult {
        changeCount += 1
        return .written(changeCount: changeCount)
    }

    func setExcludedBundleIdentifiers(_ identifiers: Set<String>) {}
}

@main
private struct ClipboardPerformanceProbe {
    private static let smallItemCount = 1_000
    private static let querySampleCount = 30
    private static let searchSampleCount = 30
    private static let hydrationSampleCount = 30
    private static let largeSampleCount = 12
    private static let largePayloadByteCount = 1_048_576

    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            print("probe.refused=\(String(describing: error))")
            exit(2)
        }
    }

    @MainActor
    private static func run() async throws {
        let arguments = try ProbeArguments(arguments: CommandLine.arguments)
        try validateOwnedPaths(arguments)
        try ensureDatabasesClosed(arguments)
        try FileManager.default.createDirectory(
            at: arguments.storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: arguments.largeDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateOwnedPaths(arguments)
        try ensureDatabasesClosed(arguments)

        if arguments.resetDataset {
            try removeOwnedDataset(at: arguments.databaseURL)
            try removeOwnedDataset(at: arguments.largeDatabaseURL)
        }

        let namedPasteboardChangeCount = seedNamedPasteboard(named: arguments.pasteboardName)
        let polling = measureUnchangedPolling()

        let retention = ClipboardHistoryRetention(
            maximumUnpinnedItems: smallItemCount,
            maximumUnpinnedAge: 30 * 24 * 60 * 60
        )
        let repository = ClipboardHistoryRepository(
            databaseURL: arguments.databaseURL,
            retention: retention
        )
        try await repository.open()
        let dataset = try await measureTextHistory(repository: repository, retention: retention)

        let largeRepository = ClipboardHistoryRepository(
            databaseURL: arguments.largeDatabaseURL,
            retention: ClipboardHistoryRetention(maximumUnpinnedItems: 100, maximumUnpinnedAge: 30 * 24 * 60 * 60),
            largePayloadThreshold: 64 * 1024
        )
        try await largeRepository.open()
        let large = try await measureLargePayload(repository: largeRepository)

        printReport(
            arguments: arguments,
            namedPasteboardChangeCount: namedPasteboardChangeCount,
            polling: polling,
            dataset: dataset,
            large: large
        )

        await repository.close()
        await largeRepository.close()
    }

    private static func validateOwnedPaths(_ arguments: ProbeArguments) throws {
        let fileManager = FileManager.default
        let buildDirectory = arguments.projectRoot.appendingPathComponent("build", isDirectory: true)
        let largeDirectory = arguments.largeDatabaseURL.deletingLastPathComponent()
        let paths: [(URL, OwnedPathKind)] = [
            (buildDirectory, .directory),
            (arguments.storageDirectory, .directory),
            (arguments.storageDirectory.appendingPathComponent("blobs", isDirectory: true), .directory),
            (largeDirectory, .directory),
            (largeDirectory.appendingPathComponent("blobs", isDirectory: true), .directory),
            (arguments.databaseURL, .regularFile),
            (URL(fileURLWithPath: arguments.databaseURL.path + "-wal"), .regularFile),
            (URL(fileURLWithPath: arguments.databaseURL.path + "-shm"), .regularFile),
            (arguments.largeDatabaseURL, .regularFile),
            (URL(fileURLWithPath: arguments.largeDatabaseURL.path + "-wal"), .regularFile),
            (URL(fileURLWithPath: arguments.largeDatabaseURL.path + "-shm"), .regularFile)
        ]

        for (url, kind) in paths {
            try validateOwnedPath(url, kind: kind, fileManager: fileManager)
        }
    }

    private static func validateOwnedPath(
        _ url: URL,
        kind: OwnedPathKind,
        fileManager: FileManager
    ) throws {
        let path = url.standardizedFileURL.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var currentPath = "/"

        for (index, component) in components.enumerated() {
            currentPath = currentPath == "/" ? "/\(component)" : "\(currentPath)/\(component)"

            if (try? fileManager.destinationOfSymbolicLink(atPath: currentPath)) != nil {
                throw ProbePathSafetyError.unsafePath
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: currentPath, isDirectory: &isDirectory) else {
                // Once an ancestor is absent, every later component is also absent.
                return
            }

            let isLeaf = index == components.count - 1
            if !isLeaf {
                guard isDirectory.boolValue else {
                    throw ProbePathSafetyError.unsafePath
                }
                continue
            }

            switch kind {
            case .directory:
                guard isDirectory.boolValue else {
                    throw ProbePathSafetyError.unsafePath
                }
            case .regularFile:
                guard !isDirectory.boolValue,
                      let attributes = try? fileManager.attributesOfItem(atPath: currentPath),
                      attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw ProbePathSafetyError.unsafePath
                }
            }
        }
    }

    private static func ensureDatabasesClosed(_ arguments: ProbeArguments) throws {
        let databasePaths = [
            arguments.databaseURL,
            URL(fileURLWithPath: arguments.databaseURL.path + "-wal"),
            URL(fileURLWithPath: arguments.databaseURL.path + "-shm"),
            arguments.largeDatabaseURL,
            URL(fileURLWithPath: arguments.largeDatabaseURL.path + "-wal"),
            URL(fileURLWithPath: arguments.largeDatabaseURL.path + "-shm")
        ]

        for url in databasePaths where FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.fileExists(atPath: "/usr/sbin/lsof") else {
                throw ProbePathSafetyError.lsofUnavailable
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-t", url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                throw ProbePathSafetyError.lsofUnavailable
            }
            process.waitUntilExit()

            switch process.terminationStatus {
            case 0:
                throw ProbePathSafetyError.databaseOpen
            case 1:
                continue
            default:
                throw ProbePathSafetyError.lsofUnavailable
            }
        }
    }

    private static func removeOwnedDataset(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        for path in [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm"
        ] {
            let url = URL(fileURLWithPath: path)
            try validateOwnedPath(url, kind: .regularFile, fileManager: fileManager)
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }
        // ClipboardBlobStore owns this sibling directory for the probe's database.
        // Do not remove it wholesale: the main dataset has no large payloads, and
        // the large dataset is in its own directory. Repository startup performs
        // safe orphan cleanup for UUID-named blob files.
    }

    @MainActor
    private static func seedNamedPasteboard(named name: String) -> Int {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        let boundary = NSPasteboardBoundary(
            pasteboard: pasteboard,
            sourceProvider: {
                ClipboardSource(appName: "Gate F Performance", bundleIdentifier: syntheticBundleIdentifier)
            }
        )
        let payload = ClipboardPayload(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            representations: [
                ClipboardRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data("Gate F performance fixture".utf8)
                )
            ],
            availableTypeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
            plainText: "Gate F performance fixture"
        )
        guard case .written(let changeCount) = boundary.write(payload: payload) else {
            return pasteboard.changeCount
        }
        return changeCount
    }

    @MainActor
    private static func measureUnchangedPolling() -> PollingMeasurement {
        let pasteboard = CountingPasteboard()
        let monitor = NSPasteboardMonitor(
            pasteboard: pasteboard,
            pollInterval: 60,
            now: { Date() }
        )
        monitor.start()
        _ = monitor.pollNow()

        var samples: [Double] = []
        samples.reserveCapacity(10_000)
        var unchangedCount = 0
        for _ in 0..<10_000 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = monitor.pollNow()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            samples.append(Double(elapsed) / 1_000_000)
            if case .unchanged = result {
                unchangedCount += 1
            }
        }
        monitor.stop()

        return PollingMeasurement(
            samplesMilliseconds: samples,
            unchangedCount: unchangedCount,
            readCount: pasteboard.readCount,
            accessState: pasteboard.accessState
        )
    }

    private static func measureTextHistory(
        repository: ClipboardHistoryRepository,
        retention: ClipboardHistoryRetention
    ) async throws -> DatasetMeasurement {
        let baseDate = Date()
        var selectedID: UUID?
        var insertSamples: [Double] = []
        insertSamples.reserveCapacity(smallItemCount)
        let insertStart = DispatchTime.now().uptimeNanoseconds

        for index in 0..<smallItemCount {
            let item = makeTextItem(index: index, date: baseDate.addingTimeInterval(-Double(index) / 10))
            if index == smallItemCount / 2 {
                selectedID = item.id
            }
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await repository.record(item, now: baseDate)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            insertSamples.append(Double(elapsed) / 1_000_000)
        }
        let insertTotal = Double(DispatchTime.now().uptimeNanoseconds - insertStart) / 1_000_000

        let rows = try await repository.history(limit: smallItemCount + 1)
        guard rows.count == smallItemCount, let selectedID else {
            throw ClipboardHistoryRepositoryError.operationFailed
        }

        _ = try await repository.history(limit: smallItemCount)
        var querySamples: [Double] = []
        querySamples.reserveCapacity(querySampleCount)
        for _ in 0..<querySampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try await repository.history(limit: smallItemCount)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard result.count == smallItemCount else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            querySamples.append(Double(elapsed) / 1_000_000)
        }

        let searchQuery = "item0500"
        let searchWarmup = try await repository.history(query: searchQuery, limit: 20)
        guard searchWarmup.count == 1 else {
            throw ClipboardHistoryRepositoryError.operationFailed
        }
        var searchSamples: [Double] = []
        searchSamples.reserveCapacity(searchSampleCount)
        for _ in 0..<searchSampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try await repository.history(query: searchQuery, limit: 20)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard result.count == 1 else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            searchSamples.append(Double(elapsed) / 1_000_000)
        }

        guard let selectedWarmup = try await repository.item(id: selectedID), selectedWarmup.payload != nil else {
            throw ClipboardHistoryRepositoryError.operationFailed
        }
        var hydrationSamples: [Double] = []
        hydrationSamples.reserveCapacity(hydrationSampleCount)
        var hydratedByteSize = 0
        for _ in 0..<hydrationSampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            guard let selected = try await repository.item(id: selectedID), let payload = selected.payload else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            hydratedByteSize = payload.byteSize
            hydrationSamples.append(Double(elapsed) / 1_000_000)
        }

        _ = retention
        return DatasetMeasurement(
            insertSamplesMilliseconds: insertSamples,
            insertTotalMilliseconds: insertTotal,
            querySamplesMilliseconds: querySamples,
            searchSamplesMilliseconds: searchSamples,
            hydrationSamplesMilliseconds: hydrationSamples,
            rowCount: rows.count,
            searchResultCount: searchWarmup.count,
            selectedHydrationByteSize: hydratedByteSize
        )
    }

    private static func measureLargePayload(
        repository: ClipboardHistoryRepository
    ) async throws -> LargePayloadMeasurement {
        let payloads = (0..<largeSampleCount).map(makeLargePayload)
        var hashSamples: [Double] = []
        hashSamples.reserveCapacity(largeSampleCount)
        for payload in payloads {
            let start = DispatchTime.now().uptimeNanoseconds
            let identity = ClipboardHasher.identity(for: payload)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard identity.count == 64 else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            hashSamples.append(Double(elapsed) / 1_000_000)
        }

        var storeSamples: [Double] = []
        storeSamples.reserveCapacity(largeSampleCount)
        var storedIDs: [UUID] = []
        storedIDs.reserveCapacity(largeSampleCount)
        for (index, payload) in payloads.enumerated() {
            let item = ClipboardItem(
                id: deterministicUUID(index: 10_000 + index),
                capture: ClipboardCapture(
                    payload: payload,
                    primaryType: .text,
                    searchableText: "gatef-large-item-\(index)",
                    source: ClipboardSource(appName: "Gate F Performance", bundleIdentifier: syntheticBundleIdentifier)
                ),
                createdAt: Date(),
                lastUsedAt: Date()
            )
            let start = DispatchTime.now().uptimeNanoseconds
            let stored = try await repository.record(item)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard stored.payloadBlobReference != nil else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            storedIDs.append(stored.id)
            storeSamples.append(Double(elapsed) / 1_000_000)
        }

        guard let selectedID = storedIDs.last else {
            throw ClipboardHistoryRepositoryError.operationFailed
        }
        guard let warmup = try await repository.item(id: selectedID), let warmupPayload = warmup.payload else {
            throw ClipboardHistoryRepositoryError.operationFailed
        }
        var hydrationSamples: [Double] = []
        hydrationSamples.reserveCapacity(largeSampleCount)
        var hydratedByteSize = warmupPayload.byteSize
        var hydratedFromBlob = warmup.payloadBlobReference != nil
        for _ in 0..<largeSampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            guard let item = try await repository.item(id: selectedID), let payload = item.payload else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            hydratedByteSize = payload.byteSize
            hydratedFromBlob = item.payloadBlobReference != nil
            hydrationSamples.append(Double(elapsed) / 1_000_000)
        }

        return LargePayloadMeasurement(
            hashSamplesMilliseconds: hashSamples,
            storeSamplesMilliseconds: storeSamples,
            hydrationSamplesMilliseconds: hydrationSamples,
            storedCount: storedIDs.count,
            hydratedByteSize: hydratedByteSize,
            hydratedFromBlob: hydratedFromBlob
        )
    }

    private static func makeTextItem(index: Int, date: Date) -> ClipboardItem {
        let token = String(format: "%04d", index)
        let text = "Gate F synthetic item\(token) item\(token)"
        let typeIdentifier = NSPasteboard.PasteboardType.string.rawValue
        let payload = ClipboardPayload(
            primaryTypeIdentifier: typeIdentifier,
            representations: [ClipboardRepresentation(typeIdentifier: typeIdentifier, data: Data(text.utf8))],
            availableTypeIdentifiers: [typeIdentifier],
            plainText: text
        )
        return ClipboardItem(
            id: deterministicUUID(index: index),
            capture: ClipboardCapture(
                payload: payload,
                primaryType: .text,
                searchableText: text,
                source: ClipboardSource(appName: "Gate F Performance", bundleIdentifier: syntheticBundleIdentifier)
            ),
            createdAt: date,
            lastUsedAt: date
        )
    }

    private static func makeLargePayload(index: Int) -> ClipboardPayload {
        var bytes = Data(repeating: 0x42, count: largePayloadByteCount)
        bytes[0] = UInt8(index & 0xff)
        let typeIdentifier = "public.data"
        return ClipboardPayload(
            primaryTypeIdentifier: typeIdentifier,
            representations: [ClipboardRepresentation(typeIdentifier: typeIdentifier, data: bytes)],
            availableTypeIdentifiers: [typeIdentifier],
            plainText: "Gate F large payload \(index)"
        )
    }

    private static func deterministicUUID(index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
    }

    private static func printReport(
        arguments: ProbeArguments,
        namedPasteboardChangeCount: Int,
        polling: PollingMeasurement,
        dataset: DatasetMeasurement,
        large: LargePayloadMeasurement
    ) {
        print("Gate F performance probe")
        print("build.optimization=swiftc -swift-version 6 -O -whole-module-optimization -warnings-as-errors")
        print("hardware.os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
#if arch(arm64)
        print("hardware.arch=arm64")
#elseif arch(x86_64)
        print("hardware.arch=x86_64")
#else
        print("hardware.arch=unknown")
#endif
        print("hardware.logicalCPUCount=\(ProcessInfo.processInfo.processorCount)")
        print("hardware.physicalMemoryBytes=\(ProcessInfo.processInfo.physicalMemory)")
        print("dataset.storageDirectory=\(arguments.storageDirectory.path)")
        print("dataset.database=\(arguments.databaseURL.path)")
        print("dataset.largeDatabase=\(arguments.largeDatabaseURL.path)")
        print("dataset.pasteboardName=\(arguments.pasteboardName)")
        print("dataset.syntheticBundleID=\(syntheticBundleIdentifier)")
        print("dataset.namedPasteboardChangeCount=\(namedPasteboardChangeCount)")
        print("dataset.reset=\(arguments.resetDataset)")
        print("warmup=repository open and one query/search/hydration call excluded from warm samples")

        print(
            "metric.unchangedPoll \(summary(polling.samplesMilliseconds)) " +
                "unchanged=\(polling.unchangedCount) reads=\(polling.readCount) access=\(polling.accessState.rawValue) " +
                "boundary=mockClipboardPasteboard nativePasteboardIPC=false"
        )
        print(
            "metric.historyInsert \(summary(dataset.insertSamplesMilliseconds)) " +
                "total_ms=\(format(dataset.insertTotalMilliseconds)) rows=\(dataset.rowCount)"
        )
        print("metric.historyQuery \(summary(dataset.querySamplesMilliseconds)) resultCount=\(dataset.rowCount)")
        print("metric.historySearch \(summary(dataset.searchSamplesMilliseconds)) resultCount=\(dataset.searchResultCount)")
        print(
            "metric.selectedHydration \(summary(dataset.hydrationSamplesMilliseconds)) " +
                "resultCount=1 payloadByteSize=\(dataset.selectedHydrationByteSize)"
        )
        print(
            "metric.largePayloadHash \(summary(large.hashSamplesMilliseconds)) " +
                "resultCount=\(large.hashSamplesMilliseconds.count) payloadByteSize=\(largePayloadByteCount)"
        )
        print(
            "metric.largePayloadStore \(summary(large.storeSamplesMilliseconds)) " +
                "resultCount=\(large.storedCount) payloadByteSize=\(largePayloadByteCount)"
        )
        print(
            "metric.largePayloadHydration \(summary(large.hydrationSamplesMilliseconds)) " +
                "resultCount=1 payloadByteSize=\(large.hydratedByteSize) blobBacked=\(large.hydratedFromBlob)"
        )
    }

    private static func summary(_ samples: [Double]) -> String {
        let values = TimingSummary(samples)
        return "samples=\(values.count) min_ms=\(format(values.minimum)) p50_ms=\(format(values.median)) p95_ms=\(format(values.p95)) max_ms=\(format(values.maximum))"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
