import ClipboardCore
import SwiftUI

struct ClipboardSettingsView: View {
    let delegate: AppDelegate
    private let externalSelectedTab: Binding<SettingsTab>?
    private let embedded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var settings: ClipboardSettingsStore
    @ObservedObject private var launchAtLogin: LaunchAtLoginController
    @ObservedObject private var panelModel: ClipboardPanelViewModel
    @ObservedObject private var controller: ClipboardHistoryController
    @FocusState private var isTabPickerFocused: Bool
    @State private var selectedTab = SettingsTab.general
    @State private var excludedBundleIdentifier = ""
    @State private var clearConfirmation = false

    private static let retentionDays = [1, 7, 30, 90]

    init(delegate: AppDelegate) {
        self.delegate = delegate
        externalSelectedTab = nil
        embedded = false
        _settings = ObservedObject(wrappedValue: delegate.settings)
        _launchAtLogin = ObservedObject(wrappedValue: delegate.launchAtLogin)
        _panelModel = ObservedObject(wrappedValue: delegate.panelModel)
        _controller = ObservedObject(wrappedValue: delegate.controller)
    }

    init(delegate: AppDelegate, selectedTab: Binding<SettingsTab>, embedded: Bool) {
        self.delegate = delegate
        externalSelectedTab = selectedTab
        self.embedded = embedded
        _settings = ObservedObject(wrappedValue: delegate.settings)
        _launchAtLogin = ObservedObject(wrappedValue: delegate.launchAtLogin)
        _panelModel = ObservedObject(wrappedValue: delegate.panelModel)
        _controller = ObservedObject(wrappedValue: delegate.controller)
    }

    var body: some View {
        Group {
            if embedded {
                embeddedContent
            } else {
                windowContent
            }
        }
        .onAppear {
            isTabPickerFocused = true
            refreshNativeStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNativeStatus()
        }
    }

    private var windowContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ClipboardReturnButton { delegate.returnToClipboard() }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))
                    Text("Changes are saved automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            GlassEffectContainer {
                Picker("Settings section", selection: activeTabSelection) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.symbolName)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .focusable()
                .focusEffectDisabled()
                .focused($isTabPickerFocused)
                .onKeyPress(.leftArrow) { moveTab(by: -1); return .handled }
                .onKeyPress(.rightArrow) { moveTab(by: 1); return .handled }
                .padding(5)
                .clipboardChrome(reduceTransparency: reduceTransparency, cornerRadius: 14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            ZStack {
                tabContent
                    .id(activeTabSelection.wrappedValue)
                    .transition(animationsEnabled ? .opacity.combined(with: .offset(y: 4)) : .identity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        // Prefer the visible navigation control over the AppKit shortcut recorder,
        // which otherwise scrolls the General form down when the window opens.
        .defaultFocus($isTabPickerFocused, true, priority: .userInitiated)
        .transaction { transaction in
            if !animationsEnabled {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var embeddedContent: some View {
        tabContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .transaction { transaction in
                if !animationsEnabled {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }

    private var animationsEnabled: Bool {
        settings.value.animationsEnabled && !reduceMotion
    }

    private func moveTab(by offset: Int) {
        let tabs = SettingsTab.allCases
        guard let index = tabs.firstIndex(of: activeTabSelection.wrappedValue) else { return }
        activeTabSelection.wrappedValue = tabs[min(max(index + offset, 0), tabs.count - 1)]
    }

    private var activeTabSelection: Binding<SettingsTab> {
        if let externalSelectedTab {
            return externalSelectedTab
        }
        return Binding(
            get: { selectedTab },
            set: { tab in
                withAnimation(animationsEnabled ? .easeInOut(duration: 0.18) : nil) {
                    selectedTab = tab
                }
            }
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTabSelection.wrappedValue {
        case .general: general
        case .privacy: privacy
        case .permissions: permissions
        }
    }

    private var general: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(
                    get: { settings.value.appearance },
                    set: { appearance in settings.update { $0.appearance = appearance } }
                )) {
                    Text("System").tag(ClipboardAppearance.system)
                    Text("Light").tag(ClipboardAppearance.light)
                    Text("Dark").tag(ClipboardAppearance.dark)
                }
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { settings.value.menuBarVisible },
                    set: { isVisible in settings.update { $0.menuBarVisible = isVisible } }
                ))
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.status == .enabled },
                    set: { enabled in delegate.updateLaunchAtLogin(enabled) }
                ))
                if launchAtLogin.status != .enabled && launchAtLogin.status != .disabled {
                    LabeledContent("Launch at login status", value: launchStatusText)
                        .foregroundStyle(.secondary)
                }
                Toggle("Animate tab changes", isOn: Binding(
                    get: { settings.value.animationsEnabled },
                    set: { enabled in settings.update { $0.animationsEnabled = enabled } }
                ))
            } header: {
                Text("Everyday use")
            } footer: {
                Text(reduceMotion
                     ? "Animations are currently disabled by macOS Reduce Motion."
                     : "Use the global shortcut to open your clipboard, even with the menu bar icon hidden.")
            }

            Section {
                Stepper(value: Binding(
                    get: { settings.value.retention.maximumUnpinnedItems },
                    set: { count in settings.update { $0.retention.maximumUnpinnedItems = count } }
                ), in: 0...10_000) {
                    LabeledContent("Maximum items") {
                        Text(settings.value.retention.maximumUnpinnedItems, format: .number)
                            .monospacedDigit()
                    }
                }
                Picker("Keep history for", selection: Binding(
                    get: { settings.value.retention.maximumUnpinnedAge },
                    set: { age in settings.update { $0.retention.maximumUnpinnedAge = age } }
                )) {
                    ForEach(Self.retentionDays, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days")
                            .tag(TimeInterval(days * 24 * 60 * 60))
                    }
                    if hasCustomRetentionAge {
                        Text(customRetentionLabel)
                            .tag(settings.value.retention.maximumUnpinnedAge)
                    }
                }
            } header: {
                Text("History limits")
            } footer: {
                Text("Unpinned items are removed when either limit is reached. Pinned items never expire. Setting the item limit to 0 keeps only pinned items.")
            }

            Section {
                LabeledContent("Open clipboard") {
                    ShortcutRecorder(configuration: Binding(
                        get: { settings.value.globalShortcut },
                        set: { configuration in settings.update { $0.globalShortcut = configuration } }
                    ))
                }
                Button("Restore Default Shortcut") {
                    settings.update { $0.globalShortcut = .default }
                }
                if let shortcutStatus = panelModel.shortcutStatus {
                    Label(shortcutStatus, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(shortcutStatus)
                }
            } header: {
                Text("Keyboard shortcut")
            } footer: {
                Text("Click the recorder, or focus it and press Return, then press your preferred key combination.")
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section {
                Toggle("Pause clipboard recording", isOn: Binding(
                    get: { settings.value.recordingPaused },
                    set: { isPaused in settings.update { $0.recordingPaused = isPaused } }
                ))
            } header: {
                Text("Recording")
            } footer: {
                Text("Clipboard history stays on this Mac. Pausing stops new captures; existing history remains available.")
            }

            Section {
                HStack(spacing: 8) {
                    TextField("Bundle identifier, e.g. com.example.app", text: $excludedBundleIdentifier)
                        .accessibilityLabel("Excluded app bundle identifier")
                        .onSubmit(addExcludedBundleIdentifier)
                    Button("Add", action: addExcludedBundleIdentifier)
                        .disabled(excludedBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if settings.value.excludedBundleIdentifiers.isEmpty {
                    Text("No excluded apps")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.value.excludedBundleIdentifiers.sorted(), id: \.self) { identifier in
                    HStack {
                        Text(identifier)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            settings.update { $0.excludedBundleIdentifiers.remove(identifier) }
                        }
                        .accessibilityLabel("Remove exclusion for \(identifier)")
                    }
                }
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("New content copied from these apps is not recorded. Concealed, transient, and auto-generated clipboard content is always excluded.")
            }

            Section {
                Button("Clear History…", role: .destructive) { clearConfirmation = true }
                    .disabled(controller.storageState != .ready)
                    .confirmationDialog("Clear clipboard history?", isPresented: $clearConfirmation) {
                        Button("Clear Unpinned", role: .destructive) { delegate.clearHistory(keepingPinned: true) }
                        Button("Clear Everything", role: .destructive) { delegate.clearHistory(keepingPinned: false) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This cannot be undone. You can keep pinned items or remove all saved history.")
                    }
                if let historyMutationFailure = panelModel.historyMutationFailure {
                    Label(historyMutationFailure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(historyMutationFailure)
                }
            } header: {
                Text("Saved history")
            } footer: {
                Text("Choose whether to keep pinned items before clearing.")
            }
        }
        .formStyle(.grouped)
    }

    private var permissions: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    Label(
                        panelModel.canAutomaticallyPaste ? "Enabled" : "Not enabled",
                        systemImage: panelModel.canAutomaticallyPaste ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .foregroundStyle(panelModel.canAutomaticallyPaste ? Color.green : Color.secondary)
                }
                Text("Accessibility lets Clipboard paste into the app you were using before opening the panel.")
                    .foregroundStyle(.secondary)
                if !panelModel.canAutomaticallyPaste {
                    Button("Enable Accessibility…") { delegate.requestAccessibilityAccess() }
                }
                Button("Refresh Permission Status", action: refreshNativeStatus)
            } header: {
                Text("Automatic paste")
            } footer: {
                Text("After changing access in System Settings, return here to refresh the status.")
            }

            Section("Always available") {
                Label("Copy from history without permission", systemImage: "doc.on.doc")
                Text("Use Copy or press ⌘Return in the clipboard panel, then press ⌘V in your app. Your history and search work without Accessibility access.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var hasCustomRetentionAge: Bool {
        !Self.retentionDays.contains { days in
            TimeInterval(days * 24 * 60 * 60) == settings.value.retention.maximumUnpinnedAge
        }
    }

    private var customRetentionLabel: String {
        let age = settings.value.retention.maximumUnpinnedAge
        if age == 0 { return "Expire immediately (custom)" }
        let days = (age / 86_400).formatted(.number.precision(.fractionLength(0...2)))
        return "Custom (\(days) days)"
    }

    private func addExcludedBundleIdentifier() {
        let identifier = excludedBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        settings.update { $0.excludedBundleIdentifiers.insert(identifier) }
        excludedBundleIdentifier = ""
    }

    private var launchStatusText: String {
        switch launchAtLogin.status {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .requiresApproval: "Requires approval in System Settings"
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

struct ClipboardHelpView: View {
    let delegate: AppDelegate
    @ObservedObject private var panelModel: ClipboardPanelViewModel

    init(delegate: AppDelegate) {
        self.delegate = delegate
        _panelModel = ObservedObject(wrappedValue: delegate.panelModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ClipboardReturnButton { delegate.returnToClipboard() }
                Text("Clipboard Help")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Open Settings") { delegate.openSettings() }
                    .buttonStyle(.bordered)
                    .focusable()
                    .clipboardKeyboardActivation { delegate.openSettings() }
                    .help("Open clipboard preferences and privacy controls")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Open clipboard") {
                            Text(panelModel.shortcutHint)
                                .monospaced()
                        }
                        .font(.headline)
                        Text("Type to search text, links, file names, or source apps. Use the tabs to filter by content type or show pinned items.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Keyboard controls")
                            .font(.headline)
                        Grid(horizontalSpacing: 24, verticalSpacing: 8) {
                            GridRow {
                                shortcut("Navigate history", keys: "↑ ↓")
                                shortcut("Paste selected", keys: "Return")
                            }
                            GridRow {
                                shortcut("Copy selected", keys: "⌘Return")
                                shortcut("Pin or unpin", keys: "⌘P")
                            }
                            GridRow {
                                shortcut("Toggle preview", keys: "Space / →")
                                shortcut("Delete selected", keys: "⌘Delete")
                            }
                            GridRow {
                                shortcut("Clear search", keys: "⌘K")
                                shortcut("Close panel", keys: "Esc")
                            }
                        }
                        Text("Select a row before using the preview keys. Return pastes into your previous app with Accessibility access. Copy always works; press ⌘V in your app to paste manually.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Private, on this Mac", systemImage: "lock.shield")
                            .font(.headline)
                        Text("History is stored locally. Pause recording or exclude apps in Settings → Privacy. History limits remove unpinned items; pinned items never expire automatically.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shortcut(_ action: String, keys: String) -> some View {
        HStack(spacing: 8) {
            Text(action)
            Spacer(minLength: 8)
            Text(keys)
                .font(.callout.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ClipboardReturnButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Clipboard", systemImage: "chevron.left")
        }
        .buttonStyle(.bordered)
        .focusable()
        .clipboardKeyboardActivation(action)
        .accessibilityLabel("Back to Clipboard")
        .help("Return to clipboard history")
    }
}

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case privacy = "Privacy"
    case permissions = "Permissions"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .permissions: "checkmark.shield"
        }
    }
}
