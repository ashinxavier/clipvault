import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @State private var choosingFolder = false
    @State private var confirmsClear = false
    @State private var confirmsClearUnpinned = false
    @State private var folderError: String?

    public init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    public var body: some View {
        Form {
            Section("General") {
                Toggle("Show menu bar icon", isOn: $preferences.showMenuBarIcon)
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                Picker("Keyboard shortcut", selection: $preferences.shortcut) {
                    ForEach(ShortcutPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Picker("Theme", selection: $preferences.appearance) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                if !model.shortcutAvailable {
                    Label("The shortcut is in use or unavailable.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("macOS may require approval in System Settings for login items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Toggle("Enable text monitoring", isOn: $preferences.textMonitoringEnabled)
                Toggle("Enable image monitoring", isOn: $preferences.imageMonitoringEnabled)
                Toggle("Enable URL and file monitoring", isOn: $preferences.urlMonitoringEnabled)
                Stepper(value: $preferences.historyLimit, in: 1...5000, step: 50) {
                    LabeledContent("Maximum history items", value: "\(preferences.historyLimit)")
                }
                Text("Application exclusions can be added through the capture policy without changing storage or restoration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Screenshots") {
                Toggle("Enable screenshot detection", isOn: $preferences.screenshotMonitoringEnabled)
                Toggle("Copy new screenshots to clipboard", isOn: $preferences.autoCopyScreenshots)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Screenshot folder")
                        .font(.subheadline.weight(.medium))
                    Text(preferences.screenshotFolderURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Button("Choose Folder…") { choosingFolder = true }
                }
            }

            Section("Storage") {
                LabeledContent("Current items", value: "\(model.itemCount)")
                LabeledContent("Local storage", value: model.storageUsageLabel)
                Button("Clear Unpinned Items…", role: .destructive) { confirmsClearUnpinned = true }
                    .disabled(model.itemCount == 0)
                Button("Clear All History…", role: .destructive) { confirmsClear = true }
                    .disabled(model.itemCount == 0)
            }

            Section("Privacy") {
                Toggle("Pause monitoring", isOn: $preferences.monitoringPaused)
                Text("Clipboard history and image assets stay on this Mac. ClipVault makes no network requests and does not log clipboard contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 550, height: 560)
        .padding(.vertical, 8)
        .fileImporter(
            isPresented: $choosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                model.setScreenshotFolder(url)
            case .failure:
                folderError = "ClipVault could not access the selected screenshot folder."
            }
        }
        .confirmationDialog(
            "Clear unpinned clipboard items?",
            isPresented: $confirmsClearUnpinned,
            titleVisibility: .visible
        ) {
            Button("Clear Unpinned Items", role: .destructive) { model.clearUnpinnedHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items will be kept. The removed items' local assets will be deleted when no longer referenced.")
        }
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes saved items and their local assets, including pinned items.")
        }
        .alert(
            "Screenshot Folder",
            isPresented: Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })
        ) {
            Button("OK") { folderError = nil }
        } message: {
            Text(folderError ?? "The selected folder could not be opened.")
        }
    }
}
