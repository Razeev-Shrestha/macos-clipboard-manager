import AppKit
import ClipboardCore
import ImageIO
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelViewModel
    @ObservedObject var controller: ClipboardHistoryController
    @ObservedObject var settings: ClipboardSettingsStore
    let makeSettingsView: (Binding<SettingsTab>) -> AnyView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedChromeControl: String?
    @State private var focusRequestGeneration = 0
    @State private var clearConfirmation = false
    @State private var destination = PanelDestination.history(.all)
    @State private var selectedSettingsTab = SettingsTab.general

    init(
        model: ClipboardPanelViewModel,
        settings: ClipboardSettingsStore,
        makeSettingsView: @escaping (Binding<SettingsTab>) -> AnyView
    ) {
        self.model = model
        controller = model.controller
        self.settings = settings
        self.makeSettingsView = makeSettingsView
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                rightPane
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            } else {
                Color.clear
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            if model.searchFocusRequest > 0 {
                focusSearchFieldAfterKeyWindowActivation()
            }
        }
        .onReceive(controller.$results) { results in
            model.acceptPublishedResults(results)
        }
        .onChange(of: model.searchFocusRequest) { _, _ in
            focusSearchFieldAfterKeyWindowActivation()
        }
        .onChange(of: focusedChromeControl) { _, control in
            model.chromeControlFocusChanged(control != nil)
        }
        .onChange(of: isSearchFocused) { _, isFocused in
            model.searchFocusChanged(isFocused)
        }
        .confirmationDialog(
            "Delete this clipboard item?",
            isPresented: Binding(
                get: { model.pendingDeletionID != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelDeleteSelected()
                    }
                }
            )
        ) {
            Button("Delete", role: .destructive) {
                model.confirmDeleteSelected()
            }
            Button("Cancel", role: .cancel) {
                model.cancelDeleteSelected()
            }
        } message: {
            Text("This item will be removed from local clipboard history.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Clipboard Manager")
                    .font(.headline)
                Text("History and preferences")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 22)

            sidebarSectionTitle("Filters")

            VStack(spacing: 3) {
                ForEach(ClipboardHistoryFilter.allCases, id: \.self) { filter in
                    SidebarNavigationRow(
                        title: filter.label == "All" ? "All Items" : filter.label,
                        systemImage: filter.symbolName,
                        count: count(for: filter),
                        isSelected: isSelected(filter),
                        action: { selectFilter(filter) }
                    )
                    .focused($focusedChromeControl, equals: "filter-\(filter.label)")
                }
            }

            sidebarSectionTitle("App Settings")
                .padding(.top, 20)

            VStack(spacing: 3) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarNavigationRow(
                        title: tab.rawValue,
                        systemImage: tab.symbolName,
                        isSelected: isSelected(tab),
                        action: { selectSettings(tab) }
                    )
                    .focused($focusedChromeControl, equals: "settings-\(tab.rawValue)")
                }
            }

            Button(action: toggleRecording) {
                Label(
                    settings.value.recordingPaused ? "Resume Recording" : "Pause Recording",
                    systemImage: settings.value.recordingPaused ? "play.fill" : "pause.fill"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 14)
            .focusable()
            .focused($focusedChromeControl, equals: "pause")
            .clipboardKeyboardActivation(toggleRecording)

            Spacer(minLength: 16)

            sidebarStatus
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(minWidth: 224, maxWidth: 224, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color.clear.background(.thinMaterial)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard Manager navigation")
    }

    private var rightPane: some View {
        VStack(spacing: 0) {
            switch destination {
            case .history:
                historyHeader
                historyCanvas
                footer
            case .settings:
                settingsHeader
                makeSettingsView($selectedSettingsTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search clipboard…", text: $controller.query)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .accessibilityLabel("Search clipboard history")
                    if !controller.query.isEmpty {
                        Button(action: clearSearch) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focusedChromeControl, equals: "clearSearch")
                        .clipboardKeyboardActivation(clearSearch)
                        .accessibilityLabel("Clear clipboard search")
                    }
                    Text(model.shortcutHint)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .clipboardChrome(reduceTransparency: reduceTransparency, cornerRadius: 12)
        }
        .padding(12)
    }

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedSettingsTab.symbolName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedSettingsTab.rawValue)
                    .font(.headline)
                Text("Changes are saved automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyCanvas: some View {
        historyContent
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(colorSchemeContrast == .increased ? 0.5 : 0.08))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }

    private var sidebarStatus: some View {
        HStack(spacing: 8) {
            Label(
                settings.value.recordingPaused ? "Recording Paused" : "Recording Active",
                systemImage: settings.value.recordingPaused ? "pause.circle" : "record.circle"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(settings.value.recordingPaused ? Color.secondary : Color.green)
            .lineLimit(1)

            Spacer(minLength: 0)

            if !model.canAutomaticallyPaste {
                Button {
                    model.requestAccessibilityAccess()
                } label: {
                    Image(systemName: "hand.raised")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .focusable()
                .focused($focusedChromeControl, equals: "accessibility")
                .clipboardKeyboardActivation { model.requestAccessibilityAccess() }
                .accessibilityLabel("Accessibility Required")
                .accessibilityHint("Requests Accessibility access for automatic paste.")
                .help("Accessibility Required")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func count(for filter: ClipboardHistoryFilter) -> Int? {
        guard controller.filter == .all || controller.filter == filter else {
            return nil
        }
        if controller.filter == filter {
            return controller.items.count
        }
        return controller.items.reduce(into: 0) { count, item in
            switch filter {
            case .all: count += 1
            case .text: count += item.primaryType == .text ? 1 : 0
            case .code: count += item.primaryType == .code ? 1 : 0
            case .links: count += item.primaryType == .url ? 1 : 0
            case .images: count += item.primaryType == .image ? 1 : 0
            case .files: count += item.primaryType == .files ? 1 : 0
            case .pinned: count += item.isPinned ? 1 : 0
            }
        }
    }

    private func isSelected(_ filter: ClipboardHistoryFilter) -> Bool {
        if case .history(let selectedFilter) = destination {
            return selectedFilter == filter
        }
        return false
    }

    private func isSelected(_ tab: SettingsTab) -> Bool {
        if case .settings(let selectedTab) = destination {
            return selectedTab == tab
        }
        return false
    }

    private func selectFilter(_ filter: ClipboardHistoryFilter) {
        withAnimation(tabAnimation) {
            destination = .history(filter)
            controller.filter = filter
        }
        model.requestSearchFocus()
    }

    private func selectSettings(_ tab: SettingsTab) {
        withAnimation(tabAnimation) {
            selectedSettingsTab = tab
            destination = .settings(tab)
        }
    }

    private func clearSearch() {
        controller.query = ""
        model.requestSearchFocus()
    }

    private func toggleRecording() {
        settings.update { $0.recordingPaused.toggle() }
    }

    private var tabAnimation: Animation? {
        reduceMotion || !settings.value.animationsEnabled ? nil : .smooth(duration: 0.18, extraBounce: 0)
    }

    /// A panel cannot make a SwiftUI field first responder until AppKit has made
    /// its window key. Multiple lifecycle requests coalesce here; none clears an
    /// already focused field while the user is typing.
    private func focusSearchFieldAfterKeyWindowActivation() {
        guard !isSearchFocused else {
            return
        }

        focusRequestGeneration &+= 1
        let generation = focusRequestGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == focusRequestGeneration,
                  NSApp.keyWindow != nil
            else {
                return
            }
            isSearchFocused = true
        }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Clipboard History Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Clipboard history is unavailable. Recording is paused. Check storage and relaunch to try again.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where controller.items.isEmpty:
            ContentUnavailableView(
                hasActiveSearchOrFilter ? "No Matching Clipboard Items" : "No Clipboard Items Yet",
                systemImage: "doc.on.clipboard",
                description: Text(emptyStateMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.isPreviewVisible, let selectedItem = model.selectedItem(in: controller.items) {
                HSplitView {
                    historyList
                    ClipboardPreview(
                        item: model.previewItem ?? selectedItem,
                        isLoading: model.isLoadingPreview,
                        previewError: model.previewError,
                        isCopying: model.isCopying,
                        canMutateHistory: model.canMutateHistory,
                        copy: model.copySelected,
                        togglePin: model.togglePinSelected,
                        delete: model.deleteSelected
                    )
                        .frame(minWidth: 300, idealWidth: 380)
                }
            } else {
                historyList
            }
        }
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(controller.items) { item in
                        ClipboardHistoryRow(
                            item: item,
                            visibleNumber: model.visibleNumber(for: item.id),
                            isSelected: model.selectedID == item.id,
                            increasedContrast: colorSchemeContrast == .increased,
                            loadImageData: { id in
                                await controller.loadImageData(id: id)
                            },
                            select: { model.select(item.id) },
                            paste: {
                                model.select(item.id)
                                model.pasteSelected()
                            },
                            copy: {
                                model.select(item.id)
                                model.copySelected()
                            },
                            togglePin: {
                                model.select(item.id)
                                model.togglePinSelected()
                            },
                            delete: {
                                model.select(item.id)
                                model.deleteSelected()
                            }
                        )
                        .id(item.id)
                        .onTapGesture(count: 2) {
                            model.select(item.id)
                            model.pasteSelected()
                        }
                    }
                }
                .padding(8)
                .scrollTargetLayout()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onScrollTargetVisibilityChange(idType: UUID.self) { ids in
                model.updateVisibleItems(ids)
            }
            .onChange(of: model.selectedID) { _, id in
                scrollToSelected(id, with: proxy)
            }
            .onChange(of: model.selectionScrollRequest) { _, _ in
                scrollToSelected(model.selectedID, with: proxy)
            }
        }
    }

    private func scrollToSelected(_ id: UUID?, with proxy: ScrollViewProxy) {
        guard let id else {
            return
        }
        proxy.scrollTo(id, anchor: .center)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let copyFailure = model.copyFailure {
                Label(copyFailure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(copyFailure)
            } else if let pasteStatus = model.pasteStatus {
                Label(pasteStatus, systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(pasteStatus)
            } else if let shortcutStatus = model.shortcutStatus {
                Label(shortcutStatus, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(shortcutStatus)
            }

            if let historyMutationFailure = model.historyMutationFailure {
                Label(historyMutationFailure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(historyMutationFailure)
            } else if controller.accessState == .denied {
                Label("Clipboard access is denied. Enable it in System Settings, then relaunch Clipboard Manager.", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.canAutomaticallyPaste {
                Button("Enable Accessibility") {
                    model.requestAccessibilityAccess()
                }
                .buttonStyle(.link)
                .font(.caption)
                .focusable()
                .focused($focusedChromeControl, equals: "accessibility")
                .clipboardKeyboardActivation { model.requestAccessibilityAccess() }
                .accessibilityHint("Requests Accessibility access for automatic paste.")
            }

            HStack(spacing: 8) {
                Label(settings.value.recordingPaused ? "Recording paused" : "Recording", systemImage: settings.value.recordingPaused ? "pause.circle" : "record.circle")
                Text("·")
                Text(controller.items.count == 1 ? "1 item" : "\(controller.items.count) items")
                Spacer()
                Button("Clear Unpinned…") {
                    clearConfirmation = true
                }
                .disabled(!model.canMutateHistory)
                .buttonStyle(.link)
                .focusable()
                .focused($focusedChromeControl, equals: "clearHistory")
                .clipboardKeyboardActivation { clearConfirmation = true }
                .confirmationDialog("Clear unpinned clipboard history?", isPresented: $clearConfirmation) {
                    Button("Clear Unpinned", role: .destructive) {
                        model.clearHistory(keepingPinned: true)
                    }
                    Button("Clear Everything", role: .destructive) {
                        model.clearHistory(keepingPinned: false)
                    }
                } message: {
                    Text("Pinned items can be retained or you can remove all clipboard history.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 8) {
                ShortcutHint(keys: ["↑", "↓"], label: "Navigate")
                ShortcutHint(keys: ["↩"], label: "Paste")
                ShortcutHint(keys: ["⌘", "↩"], label: "Copy")
                ShortcutHint(keys: ["Space"], label: "Preview")
                ShortcutHint(keys: ["⌘", "P"], label: "Pin")
                ShortcutHint(keys: ["⌘", "⌫"], label: "Delete")
                ShortcutHint(keys: ["⌘", "1–9"], label: "Paste item")
                ShortcutHint(keys: ["Esc"], label: "Close")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasActiveSearchOrFilter: Bool {
        !controller.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || controller.filter != .all
    }

    private var emptyStateMessage: String {
        switch controller.accessState {
        case .denied:
            "Clipboard access is denied. Enable Clipboard access in System Settings, then relaunch Clipboard Manager."
        case .unknown, .allowed:
            hasActiveSearchOrFilter
                ? "Adjust your search or select another filter."
                : "Copy text, links, rich text, images, or files in another app to add them here."
        }
    }
}

private enum PanelDestination: Hashable {
    case history(ClipboardHistoryFilter)
    case settings(SettingsTab)
}

private struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let count {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                }
            }
            .font(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.3 : 0.16))
            }
        }
        .overlay {
            if isSelected, colorSchemeContrast == .increased {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1)
            }
        }
        .accessibilityLabel(count.map { "\(title), \($0) items" } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ShortcutHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, key.count > 1 ? 5 : 4)
                        .frame(minWidth: 18, minHeight: 20)
                        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.12))
                        }
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined(separator: " ")): \(label)")
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let visibleNumber: Int?
    let isSelected: Bool
    let increasedContrast: Bool
    let loadImageData: (UUID) async -> Data?
    let select: () -> Void
    let paste: () -> Void
    let copy: () -> Void
    let togglePin: () -> Void
    let delete: () -> Void

    var body: some View {
        rowContent
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture(perform: select)
            .background(rowBackground)
            .overlay(rowBorder)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Press to select. Actions are available for paste, copy, pinning, and deletion.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { select() }
            .accessibilityAction(named: "Paste") { paste() }
            .accessibilityAction(named: "Copy") { copy() }
            .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") { togglePin() }
            .accessibilityAction(named: "Delete") { delete() }
    }

    @ViewBuilder
    private var rowContent: some View {
        let visibleNumberText = visibleNumber.map { String($0) } ?? ""
        HStack(alignment: .top, spacing: 10) {
            Text(visibleNumberText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            if item.primaryType == .image {
                ClipboardHistoryThumbnail(id: item.id, loadImageData: loadImageData)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryText)
                    .font(contentFont)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(sourceName)
                    Text("·")
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(item.primaryType.displayName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                .accessibilityLabel("Pinned")
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selectionFill)
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: increasedContrast ? 2 : 1)
    }

    private var selectionFill: Color {
        isSelected ? Color.accentColor.opacity(increasedContrast ? 0.42 : 0.24) : .clear
    }

    private var contentFont: Font {
        switch item.primaryType {
        case .code, .url:
            .body.monospaced()
        default:
            .body
        }
    }

    private var primaryText: String {
        item.searchableText ?? item.primaryType.displayName
    }

    private var sourceName: String {
        item.sourceAppName ?? item.sourceBundleID ?? "Unknown App"
    }

    private var accessibilityLabel: String {
        let prefix = visibleNumber.map { "\($0). " } ?? ""
        let content = primaryText
        let source = sourceName
        let pinned = item.isPinned ? ", pinned" : ""
        return "\(prefix)\(content), \(item.primaryType.displayName), from \(source), \(item.createdAt.formatted(date: .abbreviated, time: .shortened))\(pinned)"
    }
}

private struct ClipboardHistoryThumbnail: View {
    let id: UUID
    let loadImageData: (UUID) async -> Data?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 44)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 44)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityHidden(true)
        .task(id: id) {
            image = nil
            guard let data = await loadImageData(id), !Task.isCancelled,
                  let decoded = await ClipboardPreviewImageDecoder.shared.thumbnail(data: data),
                  !Task.isCancelled
            else {
                return
            }
            image = NSImage(cgImage: decoded, size: .zero)
        }
    }
}

private struct ClipboardPreview: View {
    let item: ClipboardItem
    let isLoading: Bool
    let previewError: String?
    let isCopying: Bool
    let canMutateHistory: Bool
    let copy: () -> Void
    let togglePin: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Preview", systemImage: item.primaryType.symbolName)
                    .font(.headline)
                Spacer()
                Button("Copy", action: copy)
                    .disabled(isCopying)
                Button(item.isPinned ? "Unpin" : "Pin", action: togglePin)
                Button("Delete", role: .destructive, action: delete)
                    .disabled(!canMutateHistory)
            }

            ScrollView {
                if let previewError {
                    ContentUnavailableView("Preview Unavailable", systemImage: "exclamationmark.triangle", description: Text(previewError))
                } else if isLoading {
                    ProgressView("Loading preview…")
                } else {
                    previewContent
                }
            }
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            LabeledContent("Source", value: item.sourceAppName ?? item.sourceBundleID ?? "Unknown App")
            LabeledContent("Copied", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Type", value: item.primaryType.displayName)
            if item.primaryType == .url, let url = item.payload?.url?.absoluteString ?? item.searchableText {
                LabeledContent("URL", value: url)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var previewContent: some View {
        if item.primaryType == .image,
           let data = item.payload?.representations.first(where: {
               $0.typeIdentifier == NSPasteboard.PasteboardType.png.rawValue
                   || $0.typeIdentifier == NSPasteboard.PasteboardType.tiff.rawValue
           })?.data
        {
            BoundedClipboardImage(identity: "\(item.id.uuidString):\(item.contentHash)", data: data)
        } else if item.primaryType == .files,
           let items = item.payload?.items
        {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, payloadItem in
                    let fileName = payloadItem.url?.lastPathComponent ?? payloadItem.url?.absoluteString ?? "File"
                    Text(fileName)
                        .accessibilityLabel("File \(fileName)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(item.payload?.plainText ?? item.searchableText ?? "This clipboard item has no text preview yet.")
                .font(previewFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var previewFont: Font {
        switch item.primaryType {
        case .code, .url:
            .body.monospaced()
        default:
            .body
        }
    }
}

private struct BoundedClipboardImage: View {
    let identity: String
    let data: Data
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Clipboard image preview")
            } else if didFail {
                ContentUnavailableView("Image Preview Unavailable", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("Loading image…")
            }
        }
        .task(id: identity) {
            image = nil
            didFail = false
            let decoded = await ClipboardPreviewImageDecoder.shared.thumbnail(data: data)
            guard !Task.isCancelled else { return }
            if let decoded {
                image = NSImage(cgImage: decoded, size: .zero)
            } else {
                didFail = true
            }
        }
    }
}

/// This dedicated actor serializes selected-image thumbnail work off the main
/// actor. A cancellation that arrives after ImageIO begins cannot interrupt that
/// native call, but queued canceled requests return before decoding.
private actor ClipboardPreviewImageDecoder {
    static let shared = ClipboardPreviewImageDecoder()

    func thumbnail(data: Data) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return nil
        }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        guard !Task.isCancelled else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

extension View {
    /// Explicit focusable SwiftUI buttons need activation handling when macOS
    /// keyboard navigation is off. AppKit still owns normal event delivery.
    func clipboardKeyboardActivation(_ action: @escaping () -> Void) -> some View {
        onKeyPress(keys: [.space, .return], phases: .down) { _ in
            action()
            return .handled
        }
    }

    @ViewBuilder
    func clipboardChrome(reduceTransparency: Bool, cornerRadius: CGFloat) -> some View {
        if reduceTransparency {
            self.background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

private extension ClipboardPrimaryType {
    var displayName: String {
        switch self {
        case .text: "Text"
        case .code: "Code"
        case .url: "Link"
        case .richText: "Rich Text"
        case .image: "Image"
        case .files: "Files"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .url: "link"
        case .richText: "textformat"
        case .image: "photo"
        case .files: "folder"
        case .other: "doc"
        }
    }
}

private extension ClipboardHistoryFilter {
    var symbolName: String {
        switch self {
        case .all: "square.stack"
        case .text: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .links: "link"
        case .images: "photo"
        case .files: "folder"
        case .pinned: "pin"
        }
    }

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
