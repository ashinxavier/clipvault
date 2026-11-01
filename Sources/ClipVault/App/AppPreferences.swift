import AppKit
import Combine
import Foundation
import ServiceManagement

public enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var colorScheme: ColorSchemePreference? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum ColorSchemePreference {
    case light
    case dark
}

@MainActor
public final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published public var historyLimit: Int {
        didSet { defaults.set(max(1, historyLimit), forKey: "historyLimit") }
    }
    @Published public var textMonitoringEnabled: Bool {
        didSet { defaults.set(textMonitoringEnabled, forKey: "textMonitoringEnabled") }
    }
    @Published public var imageMonitoringEnabled: Bool {
        didSet { defaults.set(imageMonitoringEnabled, forKey: "imageMonitoringEnabled") }
    }
    @Published public var urlMonitoringEnabled: Bool {
        didSet { defaults.set(urlMonitoringEnabled, forKey: "urlMonitoringEnabled") }
    }
    @Published public var screenshotMonitoringEnabled: Bool {
        didSet { defaults.set(screenshotMonitoringEnabled, forKey: "screenshotMonitoringEnabled") }
    }
    @Published public var excludedApplicationBundleIDs: [String] {
        didSet { defaults.set(excludedApplicationBundleIDs, forKey: "excludedApplicationBundleIDs") }
    }
    @Published public var autoCopyScreenshots: Bool {
        didSet { defaults.set(autoCopyScreenshots, forKey: "autoCopyScreenshots") }
    }
    @Published public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    @Published public var monitoringPaused: Bool {
        didSet { defaults.set(monitoringPaused, forKey: "monitoringPaused") }
    }
    @Published public var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published public var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }
    @Published public var shortcut: ShortcutPreset {
        didSet { defaults.set(shortcut.rawValue, forKey: "shortcut") }
    }
    @Published public var screenshotFolderURL: URL {
        didSet { saveScreenshotFolderBookmark() }
    }

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        defaults.register(defaults: [
            "historyLimit": 500,
            "textMonitoringEnabled": true,
            "imageMonitoringEnabled": true,
            "urlMonitoringEnabled": true,
            "screenshotMonitoringEnabled": true,
            "excludedApplicationBundleIDs": [],
            "autoCopyScreenshots": true,
            "launchAtLogin": true,
            "monitoringPaused": false,
            "appearance": AppearancePreference.system.rawValue,
            "showMenuBarIcon": true,
            "shortcut": ShortcutPreset.optionV.rawValue
        ])
        self.historyLimit = max(1, defaults.integer(forKey: "historyLimit"))
        self.textMonitoringEnabled = defaults.bool(forKey: "textMonitoringEnabled")
        self.imageMonitoringEnabled = defaults.bool(forKey: "imageMonitoringEnabled")
        self.urlMonitoringEnabled = defaults.bool(forKey: "urlMonitoringEnabled")
        self.screenshotMonitoringEnabled = defaults.bool(forKey: "screenshotMonitoringEnabled")
        self.excludedApplicationBundleIDs = defaults.stringArray(forKey: "excludedApplicationBundleIDs") ?? []
        self.autoCopyScreenshots = defaults.bool(forKey: "autoCopyScreenshots")
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.monitoringPaused = defaults.bool(forKey: "monitoringPaused")
        self.appearance = AppearancePreference(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        self.showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
        self.shortcut = ShortcutPreset(rawValue: defaults.string(forKey: "shortcut") ?? "") ?? .optionV
        self.screenshotFolderURL = Self.resolveFolder(defaults: defaults, fileManager: fileManager)
    }

    public func setScreenshotFolder(_ url: URL) {
        screenshotFolderURL = url.standardizedFileURL
    }

    private func saveScreenshotFolderBookmark() {
        let bookmark = (try? screenshotFolderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )) ?? (try? screenshotFolderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ))
        if let bookmark { defaults.set(bookmark, forKey: "screenshotFolderBookmark") }
        defaults.set(screenshotFolderURL.path, forKey: "screenshotFolderPath")
    }

    private static func resolveFolder(defaults: UserDefaults, fileManager: FileManager) -> URL {
        if let bookmark = defaults.data(forKey: "screenshotFolderBookmark") {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        if let path = defaults.string(forKey: "screenshotFolderPath") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}

public enum LaunchAtLoginManager {
    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else if service.status == .enabled {
            try service.unregister()
        }
    }
}
