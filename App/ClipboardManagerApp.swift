import AppKit
import ClipboardCore
import SwiftUI

@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: ClipboardHistoryController

    private let panelModel: ClipboardPanelViewModel
    private var panel: ClipboardPanelController?
    private var shortcut: GlobalClipboardShortcut?
    private var isTerminating = false

    override init() {
        let configuration = Self.makeConfiguration()
        controller = ClipboardHistoryController(
            pasteboard: configuration.pasteboard,
            databaseURL: configuration.databaseURL
        )
        panelModel = ClipboardPanelViewModel(controller: controller)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installPanelIfNeeded()
        installShortcut()

        Task { [weak controller] in
            await controller?.start()
        }

        // Gate C intentionally opens once at launch: there is no menu-bar entry yet.
        panel?.show()
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
            self.panelModel.prepareForOpening(itemIDs: self.controller.items.map(\.id))
        }
        panel.onDidClose = { [weak self] in
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
    }

    private func installShortcut() {
        let shortcut = GlobalClipboardShortcut()
        shortcut.onPressed = { [weak self] in
            self?.panel?.toggle()
        }

        do {
            try shortcut.register()
            panelModel.shortcutStatus = nil
            self.shortcut = shortcut
        } catch {
            panelModel.shortcutStatus = "⌘⇧V is unavailable because another app is using it. Open Clipboard Manager from the Dock to use its panel."
        }
    }

    private struct Configuration {
        let pasteboard: any ClipboardPasteboard
        let databaseURL: URL
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
                databaseURL: testConfiguration.databaseURL
            )
        }
        #endif

        return Configuration(
            pasteboard: NSPasteboardBoundary(
                pasteboard: .general,
                sourceProvider: sourceProvider
            ),
            databaseURL: productionDatabaseURL()
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
    }

    /// Test flags are deliberately all-or-nothing. An incomplete or unsafe flag
    /// terminates this Debug process before it can observe the general pasteboard or
    /// open the production history store.
    private static func debugTestConfiguration() -> DebugTestConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains(where: {
            $0.hasPrefix("--test-pasteboard=") || $0.hasPrefix("--test-storage-directory=")
        }) else {
            fatalError("Debug test flags require a separate value.")
        }
        let boardName = debugArgumentValue(for: "--test-pasteboard", in: arguments)
        let storageDirectory = debugArgumentValue(for: "--test-storage-directory", in: arguments)

        guard boardName != nil || storageDirectory != nil else {
            return nil
        }
        guard let boardName else {
            fatalError("--test-storage-directory requires --test-pasteboard so Debug validation stays isolated.")
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

        return DebugTestConfiguration(
            pasteboardName: boardName,
            databaseURL: directoryURL.appendingPathComponent("history.sqlite", isDirectory: false)
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
}
