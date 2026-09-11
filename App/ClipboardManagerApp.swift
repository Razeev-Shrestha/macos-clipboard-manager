import AppKit
import ClipboardCore
import SwiftUI

@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Clipboard Manager") {
            ClipboardHistoryView(controller: appDelegate.controller)
        }
        .defaultSize(width: 640, height: 460)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: ClipboardHistoryController
    private var isTerminating = false

    override init() {
        let configuration = Self.makeConfiguration()
        controller = ClipboardHistoryController(
            pasteboard: configuration.pasteboard,
            databaseURL: configuration.databaseURL
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [weak controller] in
            await controller?.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateLater
        }

        isTerminating = true
        Task { [weak self] in
            await self?.controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

private struct ClipboardHistoryView: View {
    @ObservedObject var controller: ClipboardHistoryController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search clipboard…", text: $controller.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search clipboard history")

            Picker("History filter", selection: $controller.filter) {
                ForEach(ClipboardHistoryFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            historyContent

            if controller.accessState == .denied {
                Text("Clipboard access is denied. Enable Clipboard access in System Settings, then relaunch Clipboard Manager.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clipboard access is denied. Enable Clipboard access in System Settings, then relaunch Clipboard Manager.")
            }
        }
        .padding()
    }

    @ViewBuilder
    private var historyContent: some View {
        switch controller.storageState {
        case .inactive, .opening:
            ContentUnavailableView(
                "Opening Clipboard History",
                systemImage: "externaldrive",
                description: Text("Preparing local clipboard storage.")
            )
        case .failed:
            ContentUnavailableView(
                "Clipboard History Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Clipboard history is unavailable. Recording is paused. Check storage and relaunch to try again.")
            )
        case .ready where controller.items.isEmpty:
            ContentUnavailableView(
                emptyStateTitle,
                systemImage: "doc.on.clipboard",
                description: Text(emptyStateMessage)
            )
        case .ready:
            ScrollViewReader { proxy in
                List(controller.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.searchableText ?? item.primaryType.rawValue.capitalized)
                            .lineLimit(2)
                        Text(item.sourceAppName ?? item.primaryType.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .id(item.id)
                }
                .onChange(of: historyResultIdentity) { _, _ in
                    guard let firstItemID = controller.items.first?.id else {
                        return
                    }
                    proxy.scrollTo(firstItemID, anchor: .top)
                }
            }
        }
    }

    private var historyResultIdentity: [String] {
        [controller.query, controller.filter.rawValue] + controller.items.map { $0.id.uuidString }
    }

    private var hasActiveSearchOrFilter: Bool {
        !controller.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || controller.filter != .all
    }

    private var emptyStateTitle: String {
        hasActiveSearchOrFilter ? "No Matching Clipboard Items" : "No Clipboard Items Yet"
    }

    private var emptyStateMessage: String {
        switch controller.accessState {
        case .denied:
            "Clipboard access is denied. Enable Clipboard access in System Settings, then relaunch Clipboard Manager."
        case .unknown, .allowed:
            hasActiveSearchOrFilter
                ? "Adjust your search or select another filter."
                : "Copy text or a URL in another app to add it here."
        }
    }
}

private extension ClipboardHistoryFilter {
    var label: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .code: "Code"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        case .pinned: "Pinned"
        }
    }
}
