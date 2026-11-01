@preconcurrency import AppKit
import SwiftUI

public struct HistoryPanelView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @FocusState private var searchIsFocused: Bool
    @State private var confirmsClear = false

    public init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    private var selectedItem: ClipboardItem? {
        model.items.first { $0.id == model.selectedItemID }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            filterBar
            Divider()
            historyContent
            footer
        }
        .frame(minWidth: 380, minHeight: 460)
        .background(.regularMaterial)
        .onAppear {
            model.reloadHistory()
            searchIsFocused = true
        }
        .background(
            HistoryKeyboardEventMonitor(model: model) { searchIsFocused = true }
                .frame(width: 0, height: 0)
        )
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved items and their local assets, including pinned items.")
        }
        .alert(
            "ClipVault",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "An operation could not be completed.")
        }
        .preferredColorScheme(preferredColorScheme)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("ClipVault")
                    .font(.headline)
                Text("\(model.itemCount) saved items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.shortcutAvailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .help("The selected shortcut could not be registered. Choose another shortcut in Settings.")
                    .foregroundStyle(.orange)
            }
            Button {
                model.setMonitoringPaused(!preferences.monitoringPaused)
            } label: {
                Image(systemName: preferences.monitoringPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(preferences.monitoringPaused ? "Resume monitoring" : "Pause monitoring")
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search history", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .onSubmit { if let selectedItem { model.restore(selectedItem) } }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(HistoryFilter.allCases) { filter in
                Button {
                    model.selectedFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.caption.weight(model.selectedFilter == filter ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background {
                            Capsule().fill(model.selectedFilter == filter ? Color.accentColor.opacity(0.18) : .clear)
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.selectedFilter == filter ? Color.accentColor : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private var historyContent: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.items) { item in
                            HistoryItemRow(
                                item: item,
                                isSelected: item.id == model.selectedItemID,
                                assetStore: model.assetStore,
                                onRestore: { model.restore(item) },
                                onPin: { model.togglePinned(item) },
                                onDelete: { model.delete(item) }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.selectedItemID) { _, value in
                    if let value { proxy.scrollTo(value, anchor: .center) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: preferences.monitoringPaused ? "pause.circle" : "clipboard")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            if preferences.monitoringPaused {
                Text("Monitoring is paused").font(.headline)
                Text("New clipboard items and screenshots are not being saved.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Resume Monitoring") { model.setMonitoringPaused(false) }
                    .buttonStyle(.borderedProminent)
            } else if !model.searchText.isEmpty || model.selectedFilter != .all {
                Text("No matching items").font(.headline)
                Text("Try another search or filter.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Your clipboard history is empty").font(.headline)
                Text("Copy text, a link, a file, or an image to save it here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var footer: some View {
        HStack {
            Text(preferences.monitoringPaused ? "Paused" : "Monitoring")
                .font(.caption)
                .foregroundStyle(preferences.monitoringPaused ? .orange : .secondary)
            Spacer()
            Button("Clear History", role: .destructive) { confirmsClear = true }
                .disabled(model.itemCount == 0)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

}

enum HistoryKeyCommand: Equatable {
    case previous
    case next
    case restore
    case close
    case focusSearch
    case delete
}

enum HistoryKeyRouter {
    static func command(
        forKeyCode keyCode: UInt16,
        commandPressed: Bool,
        searchIsEmpty: Bool,
        editingText: Bool
    ) -> HistoryKeyCommand? {
        if commandPressed && keyCode == 3 { return .focusSearch }
        switch keyCode {
        case 126: return .previous
        case 125: return .next
        case 36, 76: return .restore
        case 53: return .close
        case 51, 117:
            guard searchIsEmpty || !editingText else { return nil }
            return .delete
        default: return nil
        }
    }
}

enum HistorySelection {
    static func nextIndex(currentIndex: Int?, count: Int, offset: Int) -> Int? {
        guard count > 0 else { return nil }
        let current = currentIndex ?? (offset > 0 ? -1 : 0)
        return min(max(current + offset, 0), count - 1)
    }
}

private struct HistoryKeyboardEventMonitor: NSViewRepresentable {
    let model: AppModel
    let focusSearch: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.model = model
        context.coordinator.focusSearch = focusSearch
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        context.coordinator.focusSearch = focusSearch
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var model: AppModel?
        var focusSearch: () -> Void = {}
        private var monitor: Any?

        private final class EventBox: @unchecked Sendable {
            let event: NSEvent
            init(_ event: NSEvent) { self.event = event }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let box = EventBox(event)
                let handled = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(box.event)
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let model,
                  let window = event.window,
                  window is NSPanel,
                  window.title == "ClipVault" else { return false }

            guard let command = HistoryKeyRouter.command(
                forKeyCode: event.keyCode,
                commandPressed: event.modifierFlags.contains(.command),
                searchIsEmpty: model.searchText.isEmpty,
                editingText: window.firstResponder is NSTextView
            ) else { return false }

            switch command {
            case .previous:
                moveSelection(by: -1, model: model)
            case .next:
                moveSelection(by: 1, model: model)
            case .restore:
                guard let item = model.items.first(where: { $0.id == model.selectedItemID }) else { return false }
                model.restore(item)
            case .close:
                model.closeHistory()
            case .focusSearch:
                focusSearch()
            case .delete:
                guard let item = model.items.first(where: { $0.id == model.selectedItemID }) else { return false }
                model.delete(item)
            }
            return true
        }

        private func moveSelection(by offset: Int, model: AppModel) {
            let current = model.items.firstIndex { $0.id == model.selectedItemID }
            guard let next = HistorySelection.nextIndex(currentIndex: current, count: model.items.count, offset: offset) else { return }
            model.selectedItemID = model.items[next].id
        }
    }
}

private struct HistoryItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let assetStore: AssetStore?
    let onRestore: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            preview
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if item.isScreenshot {
                        Text("Screenshot")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(item.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(item.displayText ?? item.kind.title)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(item.kind == .text || item.kind == .richText ? 3 : 2)
                    .textSelection(.enabled)
                if let source = item.sourceApplicationName {
                    Label(source, systemImage: "app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 5) {
                Button(action: onPin) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(item.isPinned ? "Unpin item" : "Pin item")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete item")
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 1, perform: onRestore)
        .contextMenu {
            Button("Restore to Clipboard", action: onRestore)
            Button(item.isPinned ? "Unpin" : "Pin", action: onPin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.displayText ?? item.kind.title)
    }

    @ViewBuilder
    private var preview: some View {
        if let assetStore, let path = item.previewAssetPath,
           let url = try? assetStore.url(for: path), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 54, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: symbolName)
                .font(.title3)
                .frame(width: 54, height: 48)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .url: "link"
        case .file: "doc"
        case .image: "photo"
        }
    }
}

public struct MenuBarMenuView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @State private var confirmsClear = false

    public init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    public var body: some View {
        Group {
            Button("Open Clipboard History") { model.openHistory() }
            Button(preferences.monitoringPaused ? "Resume Monitoring" : "Pause Monitoring") {
                model.setMonitoringPaused(!preferences.monitoringPaused)
            }
            Button("Clear History…", role: .destructive) { confirmsClear = true }
                .disabled(model.itemCount == 0)
            Divider()
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Quit ClipVault") { NSApp.terminate(nil) }
        }
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved items and their local assets, including pinned items.")
        }
    }
}
