import AppKit
import ClipboardCore
import Combine
import SwiftUI

@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Clipboard Manager") {
            ClipboardHistoryView(controller: appDelegate.controller)
        }
        .defaultSize(width: 480, height: 360)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: ClipboardAppController

    override init() {
        controller = ClipboardAppController(pasteboard: Self.makePasteboard())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopMonitoring()
    }

    private static func makePasteboard() -> any ClipboardPasteboard {
        let sourceProvider = {
            let application = NSWorkspace.shared.frontmostApplication
            return ClipboardSource(
                appName: application?.localizedName,
                bundleIdentifier: application?.bundleIdentifier
            )
        }

        #if DEBUG
        if let name = debugTestPasteboardName() {
            return NSPasteboardBoundary(
                name: NSPasteboard.Name(name),
                sourceProvider: sourceProvider
            )
        }
        #endif

        return NSPasteboardBoundary(
            pasteboard: .general,
            sourceProvider: sourceProvider
        )
    }

    #if DEBUG
    private static func debugTestPasteboardName() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--test-pasteboard") else {
            return nil
        }

        let nameIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(nameIndex) else {
            fatalError("The --test-pasteboard argument requires a non-empty pasteboard name.")
        }

        let name = arguments[nameIndex]
        guard !name.isEmpty, name != NSPasteboard.Name.general.rawValue else {
            fatalError("The --test-pasteboard argument must name an isolated pasteboard.")
        }
        return name
    }
    #endif
}

@MainActor
final class ClipboardAppController: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var accessState: PasteboardAccessState = .unknown

    private let monitor: NSPasteboardMonitor

    init(pasteboard: any ClipboardPasteboard) {
        monitor = NSPasteboardMonitor(pasteboard: pasteboard)
        monitor.onPollResult = { [weak self] result, items, accessState in
            guard let self else {
                return
            }

            if case .recorded = result {
                self.items = items
            }
            if self.accessState != accessState {
                self.accessState = accessState
            }
        }
    }

    func startMonitoring() {
        monitor.start()
    }

    func stopMonitoring() {
        monitor.stop()
    }
}

private struct ClipboardHistoryView: View {
    @ObservedObject var controller: ClipboardAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clipboard History")
                .font(.title2.weight(.semibold))

            if controller.items.isEmpty {
                ContentUnavailableView(
                    "No Clipboard Items Yet",
                    systemImage: "doc.on.clipboard",
                    description: Text(emptyStateMessage)
                )
            } else {
                List(controller.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.searchableText ?? item.primaryType.rawValue.capitalized)
                            .lineLimit(2)
                        Text(item.sourceAppName ?? item.primaryType.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if controller.accessState == .denied {
                Text("Clipboard access is denied. Enable Clipboard access in System Settings, then relaunch Clipboard Manager.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clipboard access is denied. Enable Clipboard access in System Settings, then relaunch Clipboard Manager.")
            }
        }
        .padding()
    }

    private var emptyStateMessage: String {
        switch controller.accessState {
        case .denied:
            "Clipboard access is denied. Enable Clipboard access in System Settings, then relaunch Clipboard Manager."
        case .unknown, .allowed:
            "Copy text or a URL in another app to add it here."
        }
    }
}
