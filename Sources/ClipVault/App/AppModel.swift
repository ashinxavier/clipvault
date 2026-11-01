import AppKit
import Combine
import Foundation

public enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case images
    case urls
    case pinned

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var pinnedOnly: Bool { self == .pinned }

    public func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all, .pinned: true
        case .text: item.kind == .text || item.kind == .richText
        case .images: item.kind == .image
        case .urls: item.kind == .url
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    public static let shared = AppModel()

    public let preferences: AppPreferences
    public private(set) var store: SQLiteHistoryStore?
    public private(set) var assetStore: AssetStore?
    public private(set) var clipboardWriter: ClipboardWriter?

    @Published public private(set) var items: [ClipboardItem] = []
    @Published public var searchText = "" { didSet { reloadHistory() } }
    @Published public var selectedFilter: HistoryFilter = .all { didSet { reloadHistory() } }
    @Published public var selectedItemID: String?
    @Published public var errorMessage: String?
    @Published public private(set) var itemCount = 0
    @Published public private(set) var storageUsageBytes: Int64 = 0
    @Published public private(set) var shortcutAvailable = true
    @Published public private(set) var showMenuBarIcon = true

    public var onOpenHistory: (() -> Void)?
    public var onCloseHistory: (() -> Void)?

    private var clipboardMonitor: ClipboardMonitor?
    private var screenshotMonitor: ScreenshotMonitor?
    private let persistenceQueue = DispatchQueue(label: "org.clipvault.persistence", qos: .utility)
    private let shortcutManager = GlobalShortcutManager()
    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false
    private var hasSecurityScope = false
    private var scopedFolderURL: URL?

    public init(preferences: AppPreferences? = nil) {
        self.preferences = preferences ?? AppPreferences()
        self.showMenuBarIcon = self.preferences.showMenuBarIcon
        observePreferences()
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        updateShortcut()
        updateLaunchAtLogin()

        persistenceQueue.async { [weak self] in
            do {
                let supportDirectory = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("ClipVault", isDirectory: true)
                try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
                let assets = try AssetStore(rootURL: supportDirectory.appendingPathComponent("Assets", isDirectory: true))
                let history = try SQLiteHistoryStore(
                    databaseURL: supportDirectory.appendingPathComponent("history.sqlite"),
                    assetStore: assets
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.assetStore = assets
                    self.store = history
                    self.clipboardWriter = ClipboardWriter(assetStore: assets)
                    self.configureServices()
                    self.scheduleCleanup(to: self.preferences.historyLimit)
                    self.applyMonitoringPause(self.preferences.monitoringPaused)
                    self.reloadHistory()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "ClipVault could not open local history. Check available disk space and try again."
                }
            }
        }
    }

    public func openHistory() {
        onOpenHistory?()
    }

    public func closeHistory() {
        onCloseHistory?()
    }

    public func reloadHistory() {
        guard let store else { return }
        let search = searchText
        let filter = selectedFilter
        persistenceQueue.async { [weak self] in
            do {
                let items = try store.allItems(
                    search: search,
                    pinnedOnly: filter.pinnedOnly
                ).filter { filter.includes($0) }
                let count = try store.count()
                let usage = store.storageUsageBytes()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.items = items
                    self.itemCount = count
                    self.storageUsageBytes = usage
                    if let selectedItemID = self.selectedItemID,
                       !items.contains(where: { $0.id == selectedItemID }) {
                        self.selectedItemID = items.first?.id
                    } else if self.selectedItemID == nil {
                        self.selectedItemID = items.first?.id
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.showStorageError() }
            }
        }
    }

    public func restore(_ item: ClipboardItem) {
        guard let clipboardWriter else { return }
        persistenceQueue.async { [weak self] in
            do {
                try clipboardWriter.restore(item)
                DispatchQueue.main.async { [weak self] in self?.closeHistory() }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "ClipVault could not restore that clipboard item."
                }
            }
        }
    }

    public func togglePinned(_ item: ClipboardItem) {
        guard let store else { return }
        persistenceQueue.async { [weak self] in
            do {
                try store.setPinned(!item.isPinned, id: item.id)
                DispatchQueue.main.async { [weak self] in self?.reloadHistory() }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.showStorageError() }
            }
        }
    }

    public func delete(_ item: ClipboardItem) {
        guard let store else { return }
        persistenceQueue.async { [weak self] in
            do {
                _ = try store.delete(id: item.id)
                DispatchQueue.main.async { [weak self] in self?.reloadHistory() }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.reloadHistory()
                    self?.showStorageError()
                }
            }
        }
    }

    public func clearHistory() {
        guard let store else { return }
        persistenceQueue.async { [weak self] in
            do {
                try store.clearHistory()
                DispatchQueue.main.async { [weak self] in
                    self?.selectedItemID = nil
                    self?.reloadHistory()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.selectedItemID = nil
                    self?.reloadHistory()
                    self?.showStorageError()
                }
            }
        }
    }

    public func clearUnpinnedHistory() {
        guard let store else { return }
        persistenceQueue.async { [weak self] in
            do {
                _ = try store.clearUnpinned()
                DispatchQueue.main.async { [weak self] in self?.reloadHistory() }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.reloadHistory()
                    self?.showStorageError()
                }
            }
        }
    }

    public func setMonitoringPaused(_ paused: Bool) {
        if preferences.monitoringPaused != paused {
            preferences.monitoringPaused = paused
        } else {
            applyMonitoringPause(paused)
        }
    }

    public func setScreenshotFolder(_ url: URL) {
        preferences.setScreenshotFolder(url)
        guard hasStarted, !preferences.monitoringPaused else { return }
        stopFolderAccess()
        startScreenshotMonitoring()
    }

    public func setShortcut(_ shortcut: ShortcutPreset) {
        preferences.shortcut = shortcut
        updateShortcut()
    }

    public func dismissError() {
        errorMessage = nil
    }

    public var storageUsageLabel: String {
        ByteCountFormatter.string(fromByteCount: storageUsageBytes, countStyle: .file)
    }

    private func scheduleCleanup(to limit: Int) {
        guard let store else { return }
        persistenceQueue.async { [weak self] in
            do {
                _ = try store.cleanup(to: limit)
                DispatchQueue.main.async { [weak self] in self?.reloadHistory() }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.showStorageError() }
            }
        }
    }

    private func configureServices() {
        guard let store, let assetStore, let clipboardWriter else { return }
        clipboardMonitor = ClipboardMonitor(
            store: store,
            shouldCapture: { [weak self] kind, source in
                guard let self else { return false }
                let policy = DispatchQueue.main.sync {
                    var enabledKinds = Set<ClipboardContentKind>()
                    if self.preferences.textMonitoringEnabled {
                        enabledKinds.formUnion([.text, .richText])
                    }
                    if self.preferences.imageMonitoringEnabled {
                        enabledKinds.insert(.image)
                    }
                    if self.preferences.urlMonitoringEnabled {
                        enabledKinds.formUnion([.url, .file])
                    }
                    return ClipboardCapturePolicy(
                        enabledKinds: enabledKinds,
                        excludedBundleIdentifiers: Set(self.preferences.excludedApplicationBundleIDs)
                    )
                }
                return policy.allows(kind: kind, source: source)
            },
            onCapture: { [weak self] _ in
                DispatchQueue.main.async { self?.reloadHistory() }
            },
            onError: { [weak self] _ in
                DispatchQueue.main.async { self?.showStorageError() }
            }
        )
        screenshotMonitor = ScreenshotMonitor(
            store: store,
            assetStore: assetStore,
            clipboardWriter: clipboardWriter,
            autoCopyEnabled: { [weak self] in
                DispatchQueue.main.sync { self?.preferences.autoCopyScreenshots ?? false }
            },
            onCapture: { [weak self] _ in
                DispatchQueue.main.async { self?.reloadHistory() }
            },
            onError: { [weak self] _ in
                DispatchQueue.main.async { self?.errorMessage = "A clipboard or screenshot operation could not be completed." }
            }
        )
        shortcutManager.onShortcut = { [weak self] in
            DispatchQueue.main.async { self?.openHistory() }
        }
    }

    private func observePreferences() {
        preferences.$monitoringPaused
            .dropFirst()
            .sink { [weak self] paused in
                DispatchQueue.main.async { self?.applyMonitoringPause(paused) }
            }
            .store(in: &cancellables)
        preferences.$historyLimit
            .dropFirst()
            .sink { [weak self] limit in
                DispatchQueue.main.async { [weak self] in self?.scheduleCleanup(to: limit) }
            }
            .store(in: &cancellables)
        Publishers.CombineLatest4(
            preferences.$textMonitoringEnabled,
            preferences.$imageMonitoringEnabled,
            preferences.$urlMonitoringEnabled,
            preferences.$screenshotMonitoringEnabled
        )
        .dropFirst()
        .sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyMonitoringPause(self.preferences.monitoringPaused)
            }
        }
        .store(in: &cancellables)
        preferences.$showMenuBarIcon
            .dropFirst()
            .sink { [weak self] value in
                DispatchQueue.main.async { [weak self] in self?.showMenuBarIcon = value }
            }
            .store(in: &cancellables)
        preferences.$shortcut
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateShortcut() } }
            .store(in: &cancellables)
        preferences.$launchAtLogin
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                do { try LaunchAtLoginManager.setEnabled(enabled) }
                catch { self.errorMessage = "The launch-at-login setting could not be changed on this Mac." }
            }
            .store(in: &cancellables)
    }

    private func applyMonitoringPause(_ paused: Bool) {
        guard hasStarted else { return }
        if paused {
            clipboardMonitor?.stop()
            screenshotMonitor?.stop()
            stopFolderAccess()
            return
        }

        let clipboardCaptureEnabled = preferences.textMonitoringEnabled
            || preferences.imageMonitoringEnabled
            || preferences.urlMonitoringEnabled
        if clipboardCaptureEnabled {
            clipboardMonitor?.start()
        } else {
            clipboardMonitor?.stop()
        }

        if preferences.screenshotMonitoringEnabled {
            stopFolderAccess()
            startScreenshotMonitoring()
        } else {
            screenshotMonitor?.stop()
            stopFolderAccess()
        }
    }

    private func startScreenshotMonitoring() {
        let folder = preferences.screenshotFolderURL
        hasSecurityScope = folder.startAccessingSecurityScopedResource()
        scopedFolderURL = folder
        screenshotMonitor?.start(folderURL: folder)
    }

    private func stopFolderAccess() {
        if hasSecurityScope { scopedFolderURL?.stopAccessingSecurityScopedResource() }
        hasSecurityScope = false
        scopedFolderURL = nil
    }

    private func updateShortcut() {
        shortcutAvailable = shortcutManager.register(preferences.shortcut) == 0
    }

    private func updateLaunchAtLogin() {
        do { try LaunchAtLoginManager.setEnabled(preferences.launchAtLogin) }
        catch { errorMessage = "The launch-at-login setting could not be applied on this Mac." }
    }

    private func showStorageError() {
        errorMessage = "ClipVault could not update local history. Your clipboard contents were not included in logs."
    }
}
