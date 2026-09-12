import AppKit
import ClipboardCore
import SwiftUI

@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            ClipboardSettingsView(delegate: appDelegate)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let controller: ClipboardHistoryController
    let settings: ClipboardSettingsStore
    let launchAtLogin = LaunchAtLoginController()

    private static let autoPasteProbeBundleIdentifier = "com.example.ClipboardManager.AutoPasteProbe"

    let panelModel: ClipboardPanelViewModel
    private let isSyntheticPasteboardRun: Bool
    private let permittedPasteTargetURL: URL?
    private var panel: ClipboardPanelController?
    private var shortcut: GlobalClipboardShortcut?
    private var pasteCoordinator: ClipboardPasteCoordinator?
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private let lifecycleObserver = ClipboardLifecycleObserver()
    private var appliedShortcutConfiguration: GlobalClipboardShortcutConfiguration?
    private var hasStartedController = false
    private var isTerminating = false

    override init() {
        let configuration = Self.makeConfiguration()
        let settings = ClipboardSettingsStore(defaults: configuration.defaults)
        self.settings = settings
        controller = ClipboardHistoryController(
            pasteboard: configuration.pasteboard,
            databaseURL: configuration.databaseURL,
            retention: settings.value.repositoryRetention
        )
        panelModel = ClipboardPanelViewModel(controller: controller)
        isSyntheticPasteboardRun = configuration.isSyntheticPasteboardRun
        permittedPasteTargetURL = configuration.permittedPasteTargetURL
        super.init()
        lifecycleObserver.onWillSleep = { [weak controller] in controller?.handleSleep() }
        lifecycleObserver.onDidWake = { [weak controller] in controller?.handleWake() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installPanelIfNeeded()
        apply(settings.value)
        settings.onChange = { [weak self] value in self?.apply(value) }
        lifecycleObserver.start()

        Task { [weak self] in
            guard let self else { return }
            await controller.start()
            configureStatusItem(visible: settings.value.menuBarVisible)
            guard !isTerminating else { return }
            hasStartedController = true
            await applyRetention(settings.value)
        }

    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateLater
        }

        isTerminating = true
        shortcut?.unregister()
        pasteCoordinator?.shutdown()
        lifecycleObserver.stop()
        Task { [weak self] in
            await self?.controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installPanelIfNeeded() {
        guard panel == nil else {
            return
        }

        let hostingView = ClipboardPanelHostingView(rootView: ClipboardPanelView(model: panelModel))
        hostingView.onDidBecomeKey = { [weak self] in
            self?.panelModel.requestSearchFocus()
        }
        let panel = ClipboardPanelController(contentView: hostingView)
        panel.onWillShow = { [weak self] in
            guard let self else {
                return
            }
            self.pasteCoordinator?.panelDidOpen()
            self.panelModel.updateAutomaticPasteAvailability(
                self.pasteCoordinator?.canAutomaticallyPaste ?? false
            )
            self.panelModel.prepareForOpening(itemIDs: self.controller.items.map(\.id))
        }
        panel.onDidClose = { [weak self] in
            self?.pasteCoordinator?.panelDidClose()
            self?.panelModel.didClose()
        }
        panel.onKeyDown = { [weak self] event in
            guard let self else {
                return false
            }
            return self.panelModel.handleKeyDown(event)
        }

        panelModel.onPreviewVisibilityChanged = { [weak panel] isExpanded in
            panel?.setPreviewExpanded(isExpanded)
        }
        panelModel.onRequestClose = { [weak panel] in
            panel?.close(restoringFocus: true)
        }
        self.panel = panel
        installPasteCoordinator(for: panel)
    }

    private func installPasteCoordinator(for panel: ClipboardPanelController) {
        let coordinator = ClipboardPasteCoordinator(
            copyItem: { [weak controller] itemID in
                await controller?.copyItemWithReceipt(id: itemID)
            },
            restoreStillCurrent: { [weak controller] receipt in
                controller?.isRestoreCurrent(receipt) ?? false
            },
            closePanel: { [weak panel] in
                panel?.close(restoringFocus: true)
            },
            permittedTarget: { [weak self] target in
                self?.permitsAutomaticPaste(to: target) ?? false
            },
            onOutcome: { [weak panelModel] outcome in
                panelModel?.receivePasteOutcome(outcome)
            }
        )
        pasteCoordinator = coordinator

        panelModel.onPasteRequested = { [weak self, weak panel] itemID, intent in
            guard let self else {
                return
            }
            let target = ClipboardPasteTarget.capture(
                previousApplication: panel?.previousApplication
            )
            self.pasteCoordinator?.begin(itemID: itemID, intent: intent, target: target)
        }
        panelModel.onRequestAccessibilityAccess = { [weak self] in
            self?.requestAccessibilityAccess()
        }
        panelModel.onPinRequested = { [weak self] itemID in
            guard let self,
                  let item = self.controller.items.first(where: { $0.id == itemID })
            else { return }
            let action = item.isPinned ? "unpin this item" : "pin this item"
            Task { [weak self] in
                guard let self else { return }
                let didUpdate = await controller.setPinned(!item.isPinned, for: itemID)
                panelModel.receiveHistoryMutationResult(didUpdate, action: action)
            }
        }
        panelModel.onDeleteRequested = { [weak self] itemID in
            Task { [weak self] in
                guard let self else { return }
                let didDelete = await controller.deleteItem(id: itemID)
                panelModel.receiveHistoryMutationResult(didDelete, action: "delete this item")
            }
        }
        panelModel.onClearHistoryRequested = { [weak self] keepingPinned in
            self?.clearHistory(keepingPinned: keepingPinned)
        }
    }

    private func permitsAutomaticPaste(to target: ClipboardPasteTarget) -> Bool {
        guard isSyntheticPasteboardRun else {
            return true
        }
        guard let permittedPasteTargetURL,
              target.application.bundleIdentifier == Self.autoPasteProbeBundleIdentifier,
              let targetURL = target.application.bundleURL else {
            return false
        }
        return targetURL.standardizedFileURL == permittedPasteTargetURL
    }

    @discardableResult
    private func installShortcut(
        configuration: GlobalClipboardShortcutConfiguration
    ) -> GlobalClipboardShortcutConfiguration? {
        if appliedShortcutConfiguration == configuration {
            return configuration
        }
        let oldShortcut = shortcut
        oldShortcut?.unregister()
        let shortcut = GlobalClipboardShortcut(configuration: configuration)
        shortcut.onPressed = { [weak self] in
            self?.panel?.toggle()
        }

        do {
            try shortcut.register()
            panelModel.shortcutStatus = nil
            self.shortcut = shortcut
            appliedShortcutConfiguration = configuration
            return configuration
        } catch {
            let hadPreviousShortcut = oldShortcut != nil
            var restored = false
            if let oldShortcut {
                do {
                    try oldShortcut.register()
                    restored = true
                } catch {
                    restored = false
                }
            }
            if !restored {
                self.shortcut = nil
                appliedShortcutConfiguration = nil
            }
            if restored, let appliedShortcutConfiguration,
               settings.value.globalShortcut != appliedShortcutConfiguration
            {
                settings.update { $0.globalShortcut = appliedShortcutConfiguration }
            }
            if restored {
                panelModel.shortcutStatus = "The selected shortcut is unavailable. The previous shortcut remains active; open Clipboard Manager from the menu bar or Dock."
            } else if hadPreviousShortcut {
                panelModel.shortcutStatus = "The selected shortcut is unavailable and the previous shortcut could not be restored. Open Clipboard Manager from the Dock."
            } else {
                panelModel.shortcutStatus = "The selected shortcut is unavailable. Open Clipboard Manager from the menu bar or Dock."
            }
            return restored ? appliedShortcutConfiguration : nil
        }
    }

    private struct Configuration {
        let pasteboard: any ClipboardPasteboard
        let databaseURL: URL
        let isSyntheticPasteboardRun: Bool
        let permittedPasteTargetURL: URL?
        let defaults: UserDefaults
    }

    private static func makeConfiguration() -> Configuration {
        let sourceProvider = {
            let application = NSWorkspace.shared.frontmostApplication
            return ClipboardSource(
                appName: application?.localizedName,
                bundleIdentifier: application?.bundleIdentifier
            )
        }

        #if DEBUG
        if let testConfiguration = debugTestConfiguration() {
            return Configuration(
                pasteboard: NSPasteboardBoundary(
                    name: NSPasteboard.Name(testConfiguration.pasteboardName),
                    sourceProvider: sourceProvider
                ),
                databaseURL: testConfiguration.databaseURL,
                isSyntheticPasteboardRun: true,
                permittedPasteTargetURL: testConfiguration.permittedPasteTargetURL,
                defaults: testConfiguration.defaults
            )
        }
        #endif

        return Configuration(
            pasteboard: NSPasteboardBoundary(
                pasteboard: .general,
                sourceProvider: sourceProvider
            ),
            databaseURL: productionDatabaseURL(),
            isSyntheticPasteboardRun: false,
            permittedPasteTargetURL: nil,
            defaults: .standard
        )
    }

    /// The URL is computed on the main actor, while directory creation and database
    /// I/O remain inside the repository actor's asynchronous `open()` method.
    private static func productionDatabaseURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        return applicationSupport
            .appendingPathComponent("com.example.ClipboardManager", isDirectory: true)
            .appendingPathComponent("history.sqlite", isDirectory: false)
    }

    #if DEBUG
    private struct DebugTestConfiguration {
        let pasteboardName: String
        let databaseURL: URL
        let permittedPasteTargetURL: URL?
        let defaults: UserDefaults
    }

    /// Test flags are deliberately all-or-nothing. An incomplete or unsafe flag
    /// terminates this Debug process before it can observe the general pasteboard or
    /// open the production history store.
    private static func debugTestConfiguration() -> DebugTestConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains(where: {
            $0.hasPrefix("--test-pasteboard=")
                || $0.hasPrefix("--test-storage-directory=")
                || $0.hasPrefix("--test-paste-target-app-path=")
        }) else {
            fatalError("Debug test flags require a separate value.")
        }
        let boardName = debugArgumentValue(for: "--test-pasteboard", in: arguments)
        let storageDirectory = debugArgumentValue(for: "--test-storage-directory", in: arguments)
        let pasteTargetAppPath = debugArgumentValue(for: "--test-paste-target-app-path", in: arguments)

        guard boardName != nil || storageDirectory != nil || pasteTargetAppPath != nil else {
            return nil
        }
        guard let boardName else {
            fatalError("Debug storage and paste-target flags require --test-pasteboard so validation stays isolated.")
        }
        guard !boardName.isEmpty,
              boardName != "general",
              boardName != NSPasteboard.Name.general.rawValue
        else {
            fatalError("--test-pasteboard must name a non-general isolated pasteboard.")
        }

        let directoryURL: URL
        if let storageDirectory {
            guard (storageDirectory as NSString).isAbsolutePath else {
                fatalError("--test-storage-directory must be an absolute synthetic test directory.")
            }
            directoryURL = URL(fileURLWithPath: storageDirectory, isDirectory: true).standardizedFileURL
            let productionDirectory = productionDatabaseURL().deletingLastPathComponent().standardizedFileURL
            guard directoryURL != productionDirectory,
                  !directoryURL.path.hasPrefix(productionDirectory.path + "/"),
                  directoryURL.path != "/"
            else {
                fatalError("--test-storage-directory must not be the production or root directory.")
            }
        } else {
            let digest = ClipboardHasher.sha256(data: Data(boardName.utf8))
            directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipboardManager-test-\(digest.prefix(16))", isDirectory: true)
        }

        let permittedPasteTargetURL: URL?
        if let pasteTargetAppPath {
            guard (pasteTargetAppPath as NSString).isAbsolutePath else {
                fatalError("--test-paste-target-app-path must be an absolute probe app path.")
            }
            let targetURL = URL(fileURLWithPath: pasteTargetAppPath).standardizedFileURL
            guard targetURL.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: targetURL),
                  bundle.bundleIdentifier == autoPasteProbeBundleIdentifier else {
                fatalError("--test-paste-target-app-path must identify the Synthetic Auto-Paste Probe app.")
            }
            permittedPasteTargetURL = targetURL
        } else {
            permittedPasteTargetURL = nil
        }

        let suiteSeed = "\(boardName)|\(directoryURL.path)"
        let suiteName = "com.example.ClipboardManager.tests.\(ClipboardHasher.sha256(data: Data(suiteSeed.utf8)))"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated Debug settings storage.")
        }

        return DebugTestConfiguration(
            pasteboardName: boardName,
            databaseURL: directoryURL.appendingPathComponent("history.sqlite", isDirectory: false),
            permittedPasteTargetURL: permittedPasteTargetURL,
            defaults: defaults
        )
    }

    private static func debugArgumentValue(for flag: String, in arguments: [String]) -> String? {
        let indices = arguments.indices.filter { arguments[$0] == flag }
        guard indices.count <= 1 else {
            fatalError("\(flag) may appear only once.")
        }
        guard let index = indices.first else {
            return nil
        }

        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex), !arguments[valueIndex].hasPrefix("--") else {
            fatalError("\(flag) requires a value.")
        }
        return arguments[valueIndex]
    }
    #endif

    func openPanel() {
        panel?.show()
    }

    func toggleRecording() {
        settings.update { $0.recordingPaused.toggle() }
    }

    func clearHistory(keepingPinned: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let didClear = await controller.clearHistory(keepingPinned: keepingPinned)
            panelModel.receiveHistoryMutationResult(didClear, action: "clear clipboard history")
        }
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        let status = launchAtLogin.setEnabled(enabled)
        settings.update { $0.launchAtLogin = status == .enabled }
    }

    func requestAccessibilityAccess() {
        pasteCoordinator?.requestAccessibilityAccess()
        refreshAccessibilityStatus()
    }

    func refreshAccessibilityStatus() {
        panelModel.updateAutomaticPasteAvailability(pasteCoordinator?.canAutomaticallyPaste ?? false)
    }

    private func apply(_ value: ClipboardManagerSettings) {
        controller.setRecordingPaused(value.recordingPaused)
        controller.setExcludedBundleIdentifiers(value.excludedBundleIdentifiers)
        configureStatusItem(visible: value.menuBarVisible)
        NSApp.setActivationPolicy(value.menuBarVisible ? .accessory : .regular)
        let activeShortcut = installShortcut(configuration: value.globalShortcut)
        panelModel.updateShortcutHint(
            activeShortcut.map { ShortcutPresentation.text(for: $0) } ?? "Shortcut unavailable"
        )
        guard hasStartedController else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.applyRetention(value)
        }
    }

    private func applyRetention(_ value: ClipboardManagerSettings) async {
        _ = await controller.updateRetention(value.retention)
    }

    private func configureStatusItem(visible: Bool) {
        guard visible else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard Manager")
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.addItem(withTitle: "Open Clipboard", action: #selector(openClipboardFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: settings.value.recordingPaused ? "Resume Recording" : "Pause Recording", action: #selector(toggleRecordingFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        let clearHistoryItem = menu.addItem(
            withTitle: "Clear Unpinned History…",
            action: #selector(confirmClearUnpinnedFromMenu),
            keyEquivalent: ""
        )
        clearHistoryItem.isEnabled = controller.storageState == .ready
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clipboard Manager", action: #selector(quitFromMenu), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openClipboardFromMenu() { openPanel() }
    @objc private func toggleRecordingFromMenu() { toggleRecording() }
    @objc private func openSettingsFromMenu() {
        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let viewController = NSHostingController(rootView: ClipboardSettingsView(delegate: self))
            let window = NSWindow(contentViewController: viewController)
            window.title = "Clipboard Manager Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 440))
            window.center()
            window.isReleasedWhenClosed = false
            let controller = NSWindowController(window: window)
            settingsWindowController = controller
            controller.showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
    @objc private func confirmClearUnpinnedFromMenu() { confirmClearHistory(keepingPinned: true) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(confirmClearUnpinnedFromMenu) {
            return controller.storageState == .ready
        }
        return true
    }

    func confirmClearHistory(keepingPinned: Bool) {
        let alert = NSAlert()
        alert.messageText = keepingPinned ? "Clear unpinned clipboard history?" : "Clear all clipboard history?"
        alert.informativeText = keepingPinned ? "Pinned items will be kept." : "Pinned items will also be removed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearHistory(keepingPinned: keepingPinned)
    }
}
