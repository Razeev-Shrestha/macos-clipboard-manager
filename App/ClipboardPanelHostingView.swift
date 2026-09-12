import AppKit
import SwiftUI

/// Bridges the panel's actual key-window lifecycle to SwiftUI focus state.
@MainActor
final class ClipboardPanelHostingView: NSHostingView<ClipboardPanelView> {
    var onDidBecomeKey: (() -> Void)?

    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )
            self.observedWindow = nil
        }

        guard let window else {
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        observedWindow = window
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowDidBecomeKey(_ notification: Notification) {
        onDidBecomeKey?()
    }
}
