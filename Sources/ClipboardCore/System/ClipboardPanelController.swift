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
        isPresented && panel.isVisible && !panel.isMiniaturized
    }

    /// Whether this presentation is still open, including its minimized state.
    public var hasPresentedWindow: Bool {
        isPresented
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
    private static let minimumContentSize = NSSize(width: 620, height: 420)
    private static let panelStyle: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView
    ]
    private static let verticalOffset: CGFloat = 32

    private let panel: ClipboardPanel
    private let frontmostApplication: () -> NSRunningApplication?
    private var isPresented = false
    private var isMiniaturizing = false
    private var isReopeningMinimizedPanel = false
    private var isPreviewExpanded = false
    private var previousApplicationStorage: NSRunningApplication?

    public convenience init(contentView: NSView) {
        self.init(contentView: contentView, frontmostApplication: { NSWorkspace.shared.frontmostApplication })
    }

    init(contentView: NSView, frontmostApplication: @escaping () -> NSRunningApplication?) {
        self.frontmostApplication = frontmostApplication
        panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize(forContentSize: Self.compactSize)),
            styleMask: Self.panelStyle,
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.controller = self
        panel.delegate = self
        panel.contentView = contentView
        panel.title = "Clipboard Manager"
        panel.titlebarAppearsTransparent = true
        // The background can reach behind the titlebar, while AppKit's safe
        // area keeps the hosted controls below the native window controls.
        panel.contentMinSize = Self.windowSize(forContentSize: Self.minimumContentSize)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .managed, .fullScreenNone]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidChangeScreenParameters(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Shows the panel on the display containing the pointer and captures the
    /// frontmost non-self app before this app is activated. A supplied app is
    /// a fallback for returning from an auxiliary window owned by this app.
    public func show(previousApplication: NSRunningApplication? = nil) {
        guard !isVisible else {
            return
        }

        if previousApplicationStorage?.isTerminated == true {
            previousApplicationStorage = nil
        }
        capturePreviousApplication(previousApplication)
        capturePreviousApplication(frontmostApplication())
        onWillShow?()

        if let screen = preferredScreen() {
            panel.setFrame(
                Self.panelFrame(for: screen.visibleFrame, expanded: isPreviewExpanded),
                display: false
            )
        }

        isPresented = true
        NSApp.activate()
        if panel.isMiniaturized {
            isReopeningMinimizedPanel = true
            panel.deminiaturize(nil)
        }
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
        let frontmostApplication = frontmostApplication()
        isPresented = false
        isMiniaturizing = false
        isReopeningMinimizedPanel = false
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
        let requestedSize = windowSize(forContentSize: expanded ? expandedSize : compactSize)
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

    private static func windowSize(forContentSize contentSize: NSSize) -> NSSize {
        // Treat the design dimensions as usable content below the titlebar,
        // even though the background fills the complete window frame.
        NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: panelStyle.subtracting(.fullSizeContentView)
        ).size
    }

    /// Chooses a currently attached visible frame for a panel whose former screen
    /// may have been removed. A frame containing the panel center wins, then the
    /// greatest overlap, then the caller's current-pointer fallback.
    static func recoveryVisibleFrame(
        for panelFrame: NSRect,
        visibleFrames: [NSRect],
        preferredVisibleFrame: NSRect?
    ) -> NSRect? {
        guard !visibleFrames.isEmpty else {
            return nil
        }
        let panelCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
        if let containingCenter = visibleFrames.first(where: { $0.contains(panelCenter) }) {
            return containingCenter
        }
        if let overlapping = visibleFrames.max(by: { intersectionArea(panelFrame, $0) < intersectionArea(panelFrame, $1) }),
           intersectionArea(panelFrame, overlapping) > 0
        {
            return overlapping
        }
        return preferredVisibleFrame ?? visibleFrames.first
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
    private func workspaceDidActivateApplication(_ notification: Notification) {
        guard isPresented, isMiniaturizing || panel.isMiniaturized else {
            return
        }
        // A Dock thumbnail can activate us before deminiaturization finishes.
        // Remember app switches while minimized so that activation cannot erase
        // the actual destination the user was working in.
        capturePreviousApplication(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    @objc
    private func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard isVisible else {
            return
        }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let visibleFrame = Self.recoveryVisibleFrame(
            for: panel.frame,
            visibleFrames: visibleFrames,
            preferredVisibleFrame: preferredScreen()?.visibleFrame
        ) else {
            return
        }
        panel.setFrame(
            Self.panelFrame(for: visibleFrame, expanded: isPreviewExpanded),
            display: false,
            animate: false
        )
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private func capturePreviousApplication(_ frontmostApplication: NSRunningApplication?) {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        if let frontmostApplication,
           !frontmostApplication.isTerminated,
           frontmostApplication.processIdentifier > 0,
           frontmostApplication.processIdentifier != ownProcessIdentifier {
            previousApplicationStorage = frontmostApplication
        }
        // When reopening from our own menu or a minimized panel, activation
        // may already belong to us. Keep the last target until actual close.
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

    public func windowWillMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else {
            return
        }
        isMiniaturizing = true
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else {
            return
        }
        isMiniaturizing = false
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else {
            return
        }
        let wasReopenedByController = isReopeningMinimizedPanel
        isReopeningMinimizedPanel = false
        guard isPresented else {
            panel.orderOut(nil)
            return
        }
        guard !wasReopenedByController else {
            return
        }
        capturePreviousApplication(frontmostApplication())
        onWillShow?()
        panel.makeKeyAndOrderFront(nil)
    }

    public func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard window === panel else {
            return newFrame
        }
        return window.screen?.visibleFrame ?? newFrame
    }
}
