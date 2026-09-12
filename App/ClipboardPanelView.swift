import AppKit
import ClipboardCore
import ImageIO
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelViewModel
    @ObservedObject var controller: ClipboardHistoryController
    @FocusState private var isSearchFocused: Bool
    @State private var focusRequestGeneration = 0
    @State private var clearConfirmation = false

    init(model: ClipboardPanelViewModel) {
        self.model = model
        controller = model.controller
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            historyContent
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(.regularMaterial)
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

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard…", text: $controller.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search clipboard history")
                if !controller.query.isEmpty {
                    Button {
                        controller.query = ""
                        model.requestSearchFocus()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear clipboard search")
                }
                Text(model.shortcutHint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Picker("History filter", selection: $controller.filter) {
                ForEach(ClipboardHistoryFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Clipboard history filter")
        }
        .padding(12)
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
                            isSelected: model.selectedID == item.id
                        )
                        .id(item.id)
                        .onTapGesture {
                            model.select(item.id)
                        }
                        .onTapGesture(count: 2) {
                            model.select(item.id)
                            model.pasteSelected()
                        }
                    }
                }
                .padding(8)
                .scrollTargetLayout()
            }
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
                .accessibilityHint("Requests Accessibility access for automatic paste.")
            }

            HStack(spacing: 10) {
                Button("Clear Unpinned") {
                    clearConfirmation = true
                }
                .disabled(!model.canMutateHistory)
                .buttonStyle(.link)
                .font(.caption)
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
                Text("⌘P Pin")
                Text("⌘⌫ Delete")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Text("↑↓ Navigate")
                Text("↩ Paste")
                Text("⌘↩ Copy")
                Text("⌘1–9 Paste")
                Text("Space Preview")
                Text("⌘K Search")
                Text("Esc Close")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
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
                : "Copy text or a URL in another app to add it here."
        }
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let visibleNumber: Int?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(visibleNumber.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.searchableText ?? item.primaryType.displayName)
                    .font(contentFont)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(item.sourceAppName ?? item.sourceBundleID ?? "Unknown App")
                    Text("·")
                    Text(item.createdAt, style: .relative)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.20) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var contentFont: Font {
        switch item.primaryType {
        case .code, .url:
            .body.monospaced()
        default:
            .body
        }
    }

    private var accessibilityLabel: String {
        let prefix = visibleNumber.map { "\($0). " } ?? ""
        return prefix + (item.searchableText ?? item.primaryType.displayName)
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
        .background(.regularMaterial)
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
                    Text(payloadItem.url?.lastPathComponent ?? payloadItem.url?.absoluteString ?? "File")
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
