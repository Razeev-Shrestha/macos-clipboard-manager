import AppKit
import Foundation
import XCTest
@testable import ClipboardCore

@MainActor
private final class FakePasteboard: ClipboardPasteboard {
    var changeCount: Int
    var accessState: PasteboardAccessState = .unknown
    private(set) var excludedBundleIdentifiers: Set<String> = []
    var readCount = 0
    var writeCount = 0
    var resultByChangeCount: [Int: PasteboardReadResult] = [:]
    var defaultReadResult: PasteboardReadResult = .skipped(.empty)
    var nextWriteResult: PasteboardWriteResult?
    var changeCountAfterNextWrite: Int?

    init(changeCount: Int = 0) {
        self.changeCount = changeCount
    }

    func readSnapshotIfStable(expectedChangeCount: Int) -> PasteboardReadResult {
        readCount += 1
        if let result = resultByChangeCount[expectedChangeCount] {
            if case .snapshot(let snapshot) = result,
               let bundleIdentifier = snapshot.capture.source?.bundleIdentifier,
               excludedBundleIdentifiers.contains(bundleIdentifier)
            {
                return .skipped(.privacyMarker)
            }
            return result
        }
        return defaultReadResult
    }

    func write(payload: ClipboardPayload) -> PasteboardWriteResult {
        writeCount += 1
        if let result = nextWriteResult {
            nextWriteResult = nil
            if case .written(let count) = result {
                changeCount = changeCountAfterNextWrite ?? count
                changeCountAfterNextWrite = nil
            }
            return result
        }
        return .failed
    }

    func setExcludedBundleIdentifiers(_ identifiers: Set<String>) {
        excludedBundleIdentifiers = identifiers
    }
}

@MainActor
final class ClipboardCoreTests: XCTestCase {
    func testSHA256AndPayloadIdentityAreStable() {
        let helloHash = ClipboardHasher.sha256(data: Data("hello".utf8))
        XCTAssertEqual(
            helloHash,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )

        let first = ClipboardPayload(
            primaryTypeIdentifier: "public.utf8-plain-text",
            representations: [
                ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("fixture".utf8)),
                ClipboardRepresentation(typeIdentifier: "public.url", data: Data("https://example.invalid".utf8))
            ],
            plainText: "fixture"
        )
        let reordered = ClipboardPayload(
            primaryTypeIdentifier: first.primaryTypeIdentifier,
            representations: first.representations.reversed(),
            plainText: first.plainText
        )
        let changed = ClipboardPayload(
            primaryTypeIdentifier: first.primaryTypeIdentifier,
            representations: [
                ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("different".utf8))
            ],
            plainText: "different"
        )

        XCTAssertEqual(ClipboardHasher.identity(for: first), ClipboardHasher.identity(for: reordered))
        XCTAssertNotEqual(ClipboardHasher.identity(for: first), ClipboardHasher.identity(for: changed))
    }

    func testHistoryDeduplicatesAndPreservesIdentityPinAndCreation() {
        var history = InMemoryClipboardHistory()
        let firstDate = Date(timeIntervalSinceReferenceDate: 10)
        let secondDate = Date(timeIntervalSinceReferenceDate: 20)
        let firstCapture = makeCapture(text: "same", source: ClipboardSource(appName: "Editor", bundleIdentifier: "com.example.editor"))
        let secondCapture = makeCapture(text: "same", source: ClipboardSource(appName: "Terminal", bundleIdentifier: "com.example.terminal"))

        let first = history.record(firstCapture, at: firstDate)
        let firstItem = first.item
        let pinned = history.setPinned(true, for: firstItem.id)
        XCTAssertEqual(pinned?.id, firstItem.id)

        let update = history.record(secondCapture, at: secondDate)
        XCTAssertEqual(history.count, 1)
        let updated = update.item
        XCTAssertEqual(updated.id, firstItem.id)
        XCTAssertEqual(updated.createdAt, firstDate)
        XCTAssertTrue(updated.isPinned)
        XCTAssertEqual(updated.lastUsedAt, secondDate)
        XCTAssertEqual(updated.sourceBundleID, "com.example.terminal")
        XCTAssertEqual(updated.sourceAppName, "Terminal")
    }

    func testHistoryTrimsOldestUnpinnedButKeepsPinnedRows() {
        let one = ClipboardItem(capture: makeCapture(text: "one"), createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let two = ClipboardItem(capture: makeCapture(text: "two"), createdAt: Date(timeIntervalSinceReferenceDate: 2))
        let three = ClipboardItem(capture: makeCapture(text: "three"), createdAt: Date(timeIntervalSinceReferenceDate: 3))
        var history = InMemoryClipboardHistory(maxItemCount: 1, items: [one.withPinning(true), two])

        _ = history.record(three)

        XCTAssertEqual(history.items.count, 2)
        XCTAssertTrue(history.items.contains(where: { $0.id == one.id }))
        XCTAssertTrue(history.items.contains(where: { $0.id == three.id }))
        XCTAssertFalse(history.items.contains(where: { $0.id == two.id }))
    }

    func testMonitorEstablishesStartupBaselineAndSkipsUnchangedTicks() {
        let fake = FakePasteboard(changeCount: 7)
        let monitor = NSPasteboardMonitor(pasteboard: fake, now: { Date(timeIntervalSinceReferenceDate: 100) })

        monitor.start()
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 7))
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 7))
        XCTAssertEqual(fake.readCount, 0)
        monitor.stop()
    }

    func testMonitorReadsOnlyAfterAChangedCountAndPublishesCandidateWithoutRetainingPayload() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(
            pasteboard: fake,
            now: { Date(timeIntervalSinceReferenceDate: 200) }
        )
        monitor.start()

        let capture = makeCapture(text: "changed")
        fake.changeCount = 2
        fake.resultByChangeCount[2] = .snapshot(PasteboardSnapshot(changeCount: 2, capture: capture))

        let result = monitor.pollNow()
        guard case .captured(let candidate) = result else {
            XCTFail("expected an accepted capture candidate")
            return
        }
        XCTAssertEqual(candidate.snapshot.capture, capture)
        XCTAssertEqual(candidate.generation, 0)
        XCTAssertEqual(candidate.capturedAt, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(fake.readCount, 1)
        XCTAssertEqual(monitor.history.items.count, 0)

        monitor.recordPersisted(ClipboardItem(capture: capture, createdAt: candidate.capturedAt))
        XCTAssertEqual(monitor.history.items.count, 1)
        XCTAssertEqual(monitor.history.items[0].searchableText, "changed")
        XCTAssertNil(monitor.history.items[0].payload)
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 2))
        XCTAssertEqual(fake.readCount, 1)
        monitor.stop()
    }

    func testPausedRecordingAdvancesBaselineWithoutReadingOrCatchingUp() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        monitor.start()
        monitor.setRecordingPaused(true)

        fake.changeCount = 2
        fake.resultByChangeCount[2] = .snapshot(
            PasteboardSnapshot(changeCount: 2, capture: makeCapture(text: "paused"))
        )
        XCTAssertEqual(monitor.pollNow(), .paused(changeCount: 2))
        XCTAssertEqual(fake.readCount, 0)

        monitor.setRecordingPaused(false)
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 2))
        XCTAssertEqual(fake.readCount, 0)

        fake.changeCount = 3
        fake.resultByChangeCount[3] = .snapshot(
            PasteboardSnapshot(changeCount: 3, capture: makeCapture(text: "resumed"))
        )
        guard case .captured = monitor.pollNow() else {
            XCTFail("expected a post-resume capture")
            return
        }
        XCTAssertEqual(fake.readCount, 1)
        monitor.stop()
    }

    func testExclusionIsForwardedBeforeCaptureAndRejectsSource() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        monitor.start()
        monitor.setExcludedBundleIdentifiers(["com.example.private"])

        XCTAssertEqual(fake.excludedBundleIdentifiers, ["com.example.private"])
        fake.changeCount = 2
        fake.resultByChangeCount[2] = .snapshot(
            PasteboardSnapshot(
                changeCount: 2,
                capture: makeCapture(
                    text: "private",
                    source: ClipboardSource(bundleIdentifier: "com.example.private")
                )
            )
        )

        XCTAssertEqual(monitor.pollNow(), .skipped(.privacyMarker))
        monitor.stop()
    }

    func testWakeRebaselinesWithoutCatchingUpClipboardChanges() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        monitor.start()

        fake.changeCount = 2
        fake.resultByChangeCount[2] = .snapshot(
            PasteboardSnapshot(changeCount: 2, capture: makeCapture(text: "while asleep"))
        )
        monitor.handleWake()
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 2))
        XCTAssertEqual(fake.readCount, 0)
        monitor.stop()
    }

    func testSleepSkipsPollingUntilWakeAndWakeDoesNotCatchUp() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        monitor.start()

        monitor.handleSleep()
        fake.changeCount = 2
        fake.resultByChangeCount[2] = .snapshot(
            PasteboardSnapshot(changeCount: 2, capture: makeCapture(text: "while sleeping"))
        )
        XCTAssertEqual(monitor.pollNow(), .sleeping(changeCount: 2))
        XCTAssertEqual(fake.readCount, 0)

        fake.changeCount = 3
        fake.resultByChangeCount[3] = .snapshot(
            PasteboardSnapshot(changeCount: 3, capture: makeCapture(text: "also while sleeping"))
        )
        XCTAssertEqual(monitor.pollNow(), .sleeping(changeCount: 3))
        XCTAssertEqual(fake.readCount, 0)

        monitor.handleWake()
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 3))
        XCTAssertEqual(fake.readCount, 0)
        monitor.stop()
    }

    func testMetadataCacheBoundsSearchablePreview() {
        var history = InMemoryClipboardHistory()
        let longText = String(repeating: "x", count: 10_000)
        let update = history.record(makeCapture(text: longText), at: Date())

        XCTAssertEqual(update.item.searchableText?.count, 4_096)
        XCTAssertNil(update.item.payload)
    }

    func testMetadataCacheMutationHelpersRemoveClearedRows() {
        let fake = FakePasteboard()
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        let pinned = ClipboardItem(capture: makeCapture(text: "pinned"), createdAt: Date(timeIntervalSinceReferenceDate: 1))
            .withPinning(true)
        let unpinned = ClipboardItem(capture: makeCapture(text: "unpinned"), createdAt: Date(timeIntervalSinceReferenceDate: 2))
        monitor.recordPersisted(pinned)
        monitor.recordPersisted(unpinned)

        monitor.setPinned(false, for: pinned.id)
        XCTAssertFalse(monitor.history.items.first(where: { $0.id == pinned.id })?.isPinned == true)
        monitor.setPinned(true, for: pinned.id)
        monitor.clearCachedItems(keepingPinned: true)

        XCTAssertEqual(monitor.history.items.map(\.id), [pinned.id])
        monitor.removeCachedItem(id: pinned.id)
        XCTAssertTrue(monitor.history.items.isEmpty)
    }

    func testInternalRestoreIsSuppressedButLaterExternalIdenticalCopyUpdatesHistory() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(
            pasteboard: fake,
            now: { Date(timeIntervalSinceReferenceDate: 300) }
        )
        monitor.start()

        let firstCapture = makeCapture(text: "same", source: ClipboardSource(appName: "A", bundleIdentifier: "a"))
        fake.changeCount = 2
        fake.resultByChangeCount[2] = .snapshot(PasteboardSnapshot(changeCount: 2, capture: firstCapture))
        guard case .captured(let firstCandidate) = monitor.pollNow() else {
            XCTFail("expected initial capture candidate")
            return
        }
        monitor.recordPersisted(ClipboardItem(capture: firstCapture, createdAt: firstCandidate.capturedAt))
        guard let original = monitor.history.items.first else {
            XCTFail("expected initial metadata item")
            return
        }

        fake.nextWriteResult = .written(changeCount: 3)
        // The monitor cache intentionally strips payloads; restore uses the
        // durable/hydrated payload that a controller would supply.
        XCTAssertTrue(monitor.restore(firstCapture.payload))
        XCTAssertEqual(monitor.pollNow(), .selfWriteSuppressed(changeCount: 3))
        XCTAssertEqual(fake.readCount, 1)

        let externalCapture = makeCapture(text: "same", source: ClipboardSource(appName: "B", bundleIdentifier: "b"))
        fake.changeCount = 4
        fake.resultByChangeCount[4] = .snapshot(PasteboardSnapshot(changeCount: 4, capture: externalCapture))
        guard case .captured(let externalCandidate) = monitor.pollNow() else {
            XCTFail("expected external capture candidate")
            return
        }
        monitor.recordPersisted(
            ClipboardItem(capture: externalCapture, createdAt: externalCandidate.capturedAt)
        )

        XCTAssertEqual(monitor.history.items.count, 1)
        guard let updated = monitor.history.items.first else {
            XCTFail("expected updated item")
            return
        }
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(updated.sourceBundleID, "b")
        monitor.stop()
    }

    func testRacedInternalWriteIsNotSuppressed() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        monitor.start()
        let capture = makeCapture(text: "external")

        // The boundary reports the count it intended to write, but the fake's live
        // count has already advanced: another process won the race.
        fake.nextWriteResult = .written(changeCount: 2)
        fake.changeCountAfterNextWrite = 3
        XCTAssertFalse(monitor.restore(ClipboardPayload(
            primaryTypeIdentifier: "public.utf8-plain-text",
            representations: [ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("internal".utf8))],
            plainText: "internal"
        )))

        fake.resultByChangeCount[3] = .snapshot(PasteboardSnapshot(changeCount: 3, capture: capture))
        guard case .captured(let candidate) = monitor.pollNow() else {
            XCTFail("expected raced capture candidate")
            return
        }
        monitor.recordPersisted(ClipboardItem(capture: capture, createdAt: candidate.capturedAt))
        XCTAssertEqual(monitor.history.count, 1)
        XCTAssertEqual(fake.readCount, 1)
        monitor.stop()
    }

    func testMonitorRetriesOneStableSnapshotAfterMidReadRace() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        monitor.start()

        fake.changeCount = 2
        fake.resultByChangeCount[2] = .skipped(.changedDuringRead)
        XCTAssertEqual(monitor.pollNow(), .skipped(.changedDuringRead))
        XCTAssertEqual(monitor.pollNow(), .skipped(.changedDuringRead))
        XCTAssertEqual(fake.readCount, 2)

        fake.resultByChangeCount[2] = .snapshot(PasteboardSnapshot(changeCount: 2, capture: makeCapture(text: "stable")))
        // The bounded retry has been consumed; a new change is required after two
        // consecutive unstable reads, preventing work on every unchanged tick.
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 2))
        XCTAssertEqual(fake.readCount, 2)
        monitor.stop()
    }

    func testPrivacyAndUnsupportedResultsDoNotCreateHistory() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        monitor.start()

        fake.changeCount = 2
        fake.resultByChangeCount[2] = .skipped(.privacyMarker)
        XCTAssertEqual(monitor.pollNow(), .skipped(.privacyMarker))
        XCTAssertEqual(monitor.history.count, 0)

        fake.changeCount = 3
        fake.resultByChangeCount[3] = .skipped(.unsupported)
        XCTAssertEqual(monitor.pollNow(), .skipped(.unsupported))
        XCTAssertEqual(monitor.history.count, 0)
        monitor.stop()
    }

    func testDeniedAccessIsNotRetriedUntilExplicitlyRequested() {
        let fake = FakePasteboard(changeCount: 1)
        fake.accessState = .denied
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        monitor.start()

        fake.changeCount = 2
        fake.resultByChangeCount[2] = .skipped(.accessDenied)
        XCTAssertEqual(monitor.pollNow(), .skipped(.accessDenied))
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 2))
        XCTAssertEqual(fake.readCount, 1)

        monitor.retryCurrentChange()
        XCTAssertEqual(monitor.pollNow(), .skipped(.accessDenied))
        XCTAssertEqual(fake.readCount, 2)
        monitor.stop()
    }

    func testInitialDeniedAccessIsPublishedWithoutReadingUnchangedPasteboard() {
        let fake = FakePasteboard(changeCount: 7)
        fake.accessState = .denied
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        var publishedAccessState: PasteboardAccessState?
        monitor.onPollResult = { _, _, accessState in
            publishedAccessState = accessState
        }

        monitor.start()
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: 7))
        XCTAssertEqual(publishedAccessState, .denied)
        XCTAssertEqual(fake.readCount, 0)
        monitor.stop()
    }

    func testBoundaryAccessPolicyChangesPublishWithoutClipboardChangesOrPayloadReads() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("synthetic policy fixture", forType: .string))

        var accessBehavior: NSPasteboard.AccessBehavior = .alwaysDeny
        let boundary = NSPasteboardBoundary(
            pasteboard: pasteboard,
            accessBehaviorProvider: { accessBehavior }
        )
        let monitor = NSPasteboardMonitor(pasteboard: boundary)
        var publishedAccessStates: [PasteboardAccessState] = []
        monitor.onPollResult = { _, _, accessState in
            publishedAccessStates.append(accessState)
        }

        monitor.start()
        let unchangedCount = pasteboard.changeCount
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: unchangedCount))
        XCTAssertEqual(boundary.accessState, .denied)
        XCTAssertEqual(monitor.accessState, .denied)

        accessBehavior = .alwaysAllow
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: unchangedCount))
        XCTAssertEqual(boundary.accessState, .allowed)
        XCTAssertEqual(monitor.accessState, .allowed)

        accessBehavior = .ask
        XCTAssertEqual(monitor.pollNow(), .unchanged(changeCount: unchangedCount))
        XCTAssertEqual(boundary.accessState, .unknown)
        XCTAssertEqual(monitor.accessState, .unknown)

        XCTAssertEqual(publishedAccessStates, [.denied, .allowed, .unknown])
        XCTAssertEqual(monitor.history.count, 0)
        XCTAssertEqual(pasteboard.changeCount, unchangedCount)
        monitor.stop()
    }

    func testTimerLifecycleIsIdempotent() {
        let fake = FakePasteboard()
        let monitor = NSPasteboardMonitor(pasteboard: fake, pollInterval: 0.4)

        XCTAssertFalse(monitor.isRunning)
        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    func testRunningMonitorReleasesWhenItsOwnerReleasesIt() {
        let fake = FakePasteboard()
        weak var releasedMonitor: NSPasteboardMonitor?

        autoreleasepool {
            var monitor: NSPasteboardMonitor? = NSPasteboardMonitor(pasteboard: fake, pollInterval: 0.4)
            monitor?.start()
            releasedMonitor = monitor
            monitor = nil
        }

        XCTAssertNil(releasedMonitor)
    }

    func testMonitorPublishesPollResultsForAppState() {
        let fake = FakePasteboard(changeCount: 1)
        let monitor = NSPasteboardMonitor(pasteboard: fake)
        var callbackCount = 0
        var callbackHistoryCount = -1
        monitor.onPollResult = { result, items, _ in
            callbackCount += 1
            callbackHistoryCount = items.count
            if case .startupBaseline = result {
                XCTAssertEqual(items.count, 0)
            }
        }

        XCTAssertEqual(monitor.pollNow(), .startupBaseline(changeCount: 1))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(callbackHistoryCount, 0)
    }

    func testNamedPrivatePasteboardTextAndPrivacyMarker() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)

        XCTAssertEqual(boundary.accessState, .allowed)

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("synthetic clipboard fixture", forType: .string))
        let firstCount = pasteboard.changeCount
        let firstResult = boundary.readSnapshotIfStable(expectedChangeCount: firstCount)
        guard case .snapshot(let snapshot) = firstResult else {
            XCTFail("expected a text snapshot")
            return
        }
        XCTAssertEqual(snapshot.capture.primaryType, .text)
        XCTAssertEqual(snapshot.capture.searchableText, "synthetic clipboard fixture")

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardPrivacyMarkers.concealed)))
        XCTAssertTrue(pasteboard.setString("synthetic concealed fixture", forType: .string))
        let markerCount = pasteboard.changeCount
        XCTAssertEqual(boundary.readSnapshotIfStable(expectedChangeCount: markerCount), .skipped(.privacyMarker))
    }

    func testNamedPrivatePasteboardUnsupportedContentIsSafe() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.fixture.binary")))

        let result = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        XCTAssertEqual(result, .skipped(.unsupported))
    }

    func testEmptyRestorePreservesExistingPrivatePasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("synthetic preflight fixture", forType: .string))
        let originalChangeCount = pasteboard.changeCount
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let emptyPayload = ClipboardPayload(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            representations: []
        )

        XCTAssertEqual(boundary.write(payload: emptyPayload), .failed)
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic preflight fixture")
    }

    func testNamedPrivatePasteboardRestoreRoundTripAndSelfWriteSuppression() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let monitor = NSPasteboardMonitor(pasteboard: boundary)
        monitor.start()
        _ = monitor.pollNow()

        let text = "synthetic restore fixture"
        let payload = ClipboardPayload(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            representations: [
                ClipboardRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data(text.utf8)
                )
            ],
            availableTypeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
            plainText: text
        )

        XCTAssertTrue(monitor.restore(payload))
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        XCTAssertEqual(monitor.pollNow(), .selfWriteSuppressed(changeCount: pasteboard.changeCount))
        XCTAssertEqual(monitor.history.count, 0)
        monitor.stop()
    }

    func testRestoreReceiptRejectsAReplacementWithoutReadingPayload() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)
        let monitor = NSPasteboardMonitor(pasteboard: boundary)
        monitor.start()
        _ = monitor.pollNow()

        let payload = ClipboardPayload(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            representations: [
                ClipboardRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data("synthetic receipt fixture".utf8)
                )
            ],
            plainText: "synthetic receipt fixture"
        )

        guard let receipt = monitor.restoreReceipt(payload) else {
            XCTFail("expected a verified restore receipt")
            return
        }
        XCTAssertEqual(receipt.changeCount, pasteboard.changeCount)
        XCTAssertTrue(monitor.isCurrent(receipt))

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("synthetic external replacement", forType: .string))
        XCTAssertFalse(monitor.isCurrent(receipt))
        monitor.stop()
    }

    func testNamedPrivatePasteboardURLAndMalformedURLAreSafe() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("https://example.invalid/fixture", forType: .URL))
        let urlResult = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount)
        guard case .snapshot(let snapshot) = urlResult else {
            XCTFail("expected a URL snapshot")
            return
        }
        XCTAssertEqual(snapshot.capture.primaryType, .url)
        XCTAssertEqual(snapshot.capture.payload.url?.absoluteString, "https://example.invalid/fixture")

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setData(Data([0xff, 0x00]), forType: .URL))
        XCTAssertEqual(
            boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount),
            .skipped(.malformed)
        )
    }

    func testNamedPrivatePasteboardWWWTextIsRecognizedAsURL() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let boundary = NSPasteboardBoundary(pasteboard: pasteboard)

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        XCTAssertTrue(pasteboard.setString("www.example.invalid/fixture", forType: .string))

        guard case .snapshot(let snapshot) = boundary.readSnapshotIfStable(expectedChangeCount: pasteboard.changeCount) else {
            XCTFail("expected a URL snapshot")
            return
        }
        XCTAssertEqual(snapshot.capture.primaryType, .url)
        XCTAssertEqual(snapshot.capture.payload.url?.absoluteString, "https://www.example.invalid/fixture")
    }

    private func makeCapture(text: String, source: ClipboardSource? = nil) -> ClipboardCapture {
        let payload = ClipboardPayload(
            primaryTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            representations: [
                ClipboardRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data(text.utf8)
                )
            ],
            availableTypeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
            plainText: text
        )
        return ClipboardCapture(payload: payload, primaryType: .text, searchableText: text, source: source)
    }
}
