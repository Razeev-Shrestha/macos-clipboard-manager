import ClipboardCore
import SwiftUI

struct ClipboardSettingsView: View {
    let delegate: AppDelegate
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var settings: ClipboardSettingsStore
    @ObservedObject private var launchAtLogin: LaunchAtLoginController
    @ObservedObject private var panelModel: ClipboardPanelViewModel
    @ObservedObject private var controller: ClipboardHistoryController
    @State private var excludedBundleIdentifier = ""
    @State private var clearConfirmation = false

    init(delegate: AppDelegate) {
        self.delegate = delegate
        _settings = ObservedObject(wrappedValue: delegate.settings)
        _launchAtLogin = ObservedObject(wrappedValue: delegate.launchAtLogin)
        _panelModel = ObservedObject(wrappedValue: delegate.panelModel)
        _controller = ObservedObject(wrappedValue: delegate.controller)
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            TabView {
                general
                    .tabItem { Label("General", systemImage: "gear") }
                privacy
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }
                permissions
                    .tabItem { Label("Permissions", systemImage: "checkmark.shield") }
            }
            .padding(20)
            .clipboardChrome(reduceTransparency: reduceTransparency, cornerRadius: 22)
        }
        .frame(width: 560, height: 400)
        .onAppear {
            refreshNativeStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNativeStatus()
        }
    }

    private var general: some View {
        Form {
            Toggle("Show menu bar icon", isOn: Binding<Bool>(
                get: { settings.value.menuBarVisible },
                set: { isVisible in settings.update { $0.menuBarVisible = isVisible } }
            ))
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.status == .enabled },
                set: { enabled in delegate.updateLaunchAtLogin(enabled) }
            ))
            LabeledContent("Launch at login status", value: launchStatusText)
            Stepper("Keep up to \(settings.value.retention.maximumUnpinnedItems) unpinned items", value: Binding(
                get: { settings.value.retention.maximumUnpinnedItems },
                set: { count in settings.update { $0.retention.maximumUnpinnedItems = count } }
            ), in: 0...10_000)
            LabeledContent("Global shortcut") {
                ShortcutRecorder(configuration: Binding(
                    get: { settings.value.globalShortcut },
                    set: { configuration in settings.update { $0.globalShortcut = configuration } }
                ))
            }
            Text("Click the recorder, or press Return while it is focused, then press one shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Restore Default Shortcut") {
                settings.update { $0.globalShortcut = .default }
            }
            if let shortcutStatus = panelModel.shortcutStatus {
                Label(shortcutStatus, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(shortcutStatus)
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Toggle("Pause clipboard recording", isOn: Binding<Bool>(
                get: { settings.value.recordingPaused },
                set: { isPaused in settings.update { $0.recordingPaused = isPaused } }
            ))
            Section("Excluded Apps") {
                HStack {
                    TextField("Bundle identifier", text: $excludedBundleIdentifier)
                    Button("Add", action: addExcludedBundleIdentifier)
                        .disabled(excludedBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(settings.value.excludedBundleIdentifiers.sorted(), id: \.self) { identifier in
                    HStack {
                        Text(identifier)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            settings.update { $0.excludedBundleIdentifiers.remove(identifier) }
                        }
                    }
                }
            }
            Section("Sensitive clipboard markers") {
                Text("Concealed, transient, and auto-generated pasteboard markers are always excluded before content is captured.")
                    .foregroundStyle(.secondary)
            }
            Section("Clear history") {
                Button("Clear Unpinned History…", role: .destructive) { clearConfirmation = true }
                    .disabled(controller.storageState != .ready)
                    .confirmationDialog("Clear clipboard history?", isPresented: $clearConfirmation) {
                        Button("Clear Unpinned", role: .destructive) { delegate.clearHistory(keepingPinned: true) }
                        Button("Clear Everything", role: .destructive) { delegate.clearHistory(keepingPinned: false) }
                    } message: {
                    Text("Choose whether to retain pinned items.")
                }
                if let historyMutationFailure = panelModel.historyMutationFailure {
                    Label(historyMutationFailure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(historyMutationFailure)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var permissions: some View {
        Form {
            LabeledContent("Accessibility", value: panelModel.canAutomaticallyPaste ? "Enabled" : "Not enabled")
            Text("Accessibility is used only to paste into the app that was active before the clipboard panel opened.")
                .foregroundStyle(.secondary)
            Button("Enable Accessibility") { delegate.requestAccessibilityAccess() }
        }
        .formStyle(.grouped)
    }

    private func addExcludedBundleIdentifier() {
        let identifier = excludedBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.excludedBundleIdentifiers.insert(identifier) }
        excludedBundleIdentifier = ""
    }

    private var launchStatusText: String {
        switch launchAtLogin.status {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .requiresApproval: "Requires approval"
        case .unavailable: "Unavailable"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }

    private func refreshNativeStatus() {
        launchAtLogin.refresh()
        delegate.refreshAccessibilityStatus()
    }
}
