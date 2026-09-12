import AppKit
import Foundation
import XCTest
@testable import ClipboardCore

@MainActor
final class ClipboardLifecycleObserverTests: XCTestCase {
    func testSleepAndWakeNotificationsForwardInOrderAndStopRemovesObservers() {
        let center = NotificationCenter()
        let observer = ClipboardLifecycleObserver(notificationCenter: center)
        var events: [String] = []
        observer.onWillSleep = { events.append("sleep") }
        observer.onDidWake = { events.append("wake") }

        observer.start()
        observer.start()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(events, ["sleep"])
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(events, ["sleep", "wake"])

        observer.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(events, ["sleep", "wake"])
    }
}
