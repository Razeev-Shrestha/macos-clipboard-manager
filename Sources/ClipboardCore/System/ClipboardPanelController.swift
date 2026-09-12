import AppKit

private final class ClipboardPanel: NSPanel {
    weak var controller: ClipboardPanelController?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }

        if controller?.onKeyDown?(event) == true {
            return
        }

        if event.keyCode == 53 { // Escape
            controller?.close(restoringFocus: true)
            return
        }

        // Intercepting here runs before a focused SwiftUI field editor. Any
        // key the panel does not own continues through AppKit's normal
        // responder chain, so text editing remains native.
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.close(restoringFocus: true)
    }
}

/// Owns the reusable floating panel shell used by the clipboard workflow.
///
/// The controller deliberately owns no clipboard or SwiftUI state. The host
/// supplies an AppKit content view and uses the callbacks to reset selection,
/// request search focus, and handle keyboard actions.
@MainActor
public final class ClipboardPanelController: NSObject, NSWindowDelegate {
    public var onWillShow: (() -> Void)?
    public var onDidClose: (() -> Void)?
    public var onKeyDown: ((NSEvent) -> Bool)?

    public var isVisible: Bool {
        isPresented && panel.isVisible
    }

    public var previousApplication: NSRunningApplication? {
        previousApplicationStorage
    }

    /// Exposed internally for deterministic tests; callers should use the
    /// initializer's view reference rather than relying on this implementation
    /// detail.
    var contentView: NSView? {
        panel.contentView
    }

    private static let compactSize = NSSize(width: 760, height: 520)
    private static let expandedSize = NSSize(width: 1_040, height: 640)
    private static let verticalOffset: CGFloat = 32

    private let panel: ClipboardPanel
    private var isPresented = false
    private var isPreviewExpanded = false
    private var previousApplicationStorage: NSRunningApplication?

    public init(contentView: NSView) {
        panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.controller = self
        panel.delegate = self
        panel.contentView = contentView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Shows the panel on the display containing the pointer and captures the
    /// frontmost non-self app before this app is activated.
    public func show() {
        guard !isVisible else {
            return
        }

        capturePreviousApplication()
        onWillShow?()

        if let screen = preferredScreen() {
            panel.setFrame(
                Self.panelFrame(for: screen.visibleFrame, expanded: isPreviewExpanded),
                display: false
            )
        }

        isPresented = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    public func toggle() {
        if isVisible {
            close(restoringFocus: true)
        } else {
            show()
        }
    }

    /// Hides the reusable panel. Focus returns only when the user has not
    /// already moved to another app and the captured app is still alive.
    public func close(restoringFocus: Bool = true) {
        guard isPresented || panel.isVisible else {
            return
        }

        let previousApplication = previousApplicationStorage
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        isPresented = false
        panel.orderOut(nil)

        if Self.shouldRestoreFocus(
            restoringFocus: restoringFocus,
            previousProcessIdentifier: previousApplication?.processIdentifier,
            previousApplicationTerminated: previousApplication?.isTerminated ?? true,
            frontmostProcessIdentifier: frontmostApplication?.processIdentifier,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        ), let previousApplication {
            // Cooperatively yield before requesting activation so the app that
            // was captured before showing the panel can reclaim focus without
            // fighting the current application.
            NSApp.yieldActivation(to: previousApplication)
            _ = previousApplication.activate(options: [])
        }

        previousApplicationStorage = nil
        onDidClose?()
    }

    public func setPreviewExpanded(_ expanded: Bool) {
        guard isPreviewExpanded != expanded else {
            return
        }

        isPreviewExpanded = expanded
        guard isVisible else {
            return
        }

        let screen = panel.screen ?? preferredScreen()
        if let screen {
            panel.setFrame(
                Self.panelFrame(for: screen.visibleFrame, expanded: expanded),
                display: true,
                animate: false
            )
        }
    }

    static func panelFrame(for visibleFrame: NSRect, expanded: Bool) -> NSRect {
        let requestedSize = expanded ? expandedSize : compactSize
        let width = min(requestedSize.width, max(0, visibleFrame.width))
        let height = min(requestedSize.height, max(0, visibleFrame.height))
        let size = NSSize(width: width, height: height)

        let unclampedOrigin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2 + verticalOffset
        )
        let maxX = visibleFrame.maxX - size.width
        let maxY = visibleFrame.maxY - size.height
        let origin = NSPoint(
            x: min(max(unclampedOrigin.x, visibleFrame.minX), maxX),
            y: min(max(unclampedOrigin.y, visibleFrame.minY), maxY)
        )
        return NSRect(origin: origin, size: size)
    }

    static func shouldRestoreFocus(
        restoringFocus: Bool,
        previousProcessIdentifier: pid_t?,
        previousApplicationTerminated: Bool,
        frontmostProcessIdentifier: pid_t?,
        ownProcessIdentifier: pid_t
    ) -> Bool {
        guard restoringFocus,
              let previousProcessIdentifier,
              previousProcessIdentifier != ownProcessIdentifier,
              !previousApplicationTerminated
        else {
            return false
        }

        // A nil frontmost app is possible during an activation transition. In
        // that case the captured app is still safe to activate. Any different
        // live frontmost process means the user deliberately changed apps.
        return frontmostProcessIdentifier == nil
            || frontmostProcessIdentifier == ownProcessIdentifier
    }

    @objc
    private func applicationDidResignActive(_ notification: Notification) {
        guard isPresented else {
            return
        }
        close(restoringFocus: false)
    }

    private func capturePreviousApplication() {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if let frontmostApplication,
           frontmostApplication.processIdentifier != ownProcessIdentifier {
            previousApplicationStorage = frontmostApplication
        } else {
            previousApplicationStorage = nil
        }
    }

    private func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel else {
            return true
        }
        close(restoringFocus: true)
        return false
    }
}
