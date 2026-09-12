import AppKit
import Foundation

/// Observes native workspace sleep notifications without owning the monitor or
/// repository. Tests inject a private NotificationCenter and never change system
/// power state.
@MainActor
public final class ClipboardLifecycleObserver {
    public var onWillSleep: (() -> Void)?
    public var onDidWake: (() -> Void)?

    private let notificationCenter: NotificationCenter
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isStarted = false

    public init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
    }

    isolated deinit {
        stop()
    }

    public func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // OperationQueue.main delivers this block synchronously when the
            // notification is posted on the main queue. The explicit assertion
            // keeps delivery on this @MainActor type without an untracked Task.
            MainActor.assumeIsolated {
                self?.deliverWillSleep()
            }
        }
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deliverDidWake()
            }
        }
    }

    public func stop() {
        isStarted = false
        if let sleepObserver {
            notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func deliverWillSleep() {
        guard isStarted else {
            return
        }
        onWillSleep?()
    }

    private func deliverDidWake() {
        guard isStarted else {
            return
        }
        onDidWake?()
    }
}
