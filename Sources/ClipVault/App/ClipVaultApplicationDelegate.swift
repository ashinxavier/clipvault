import AppKit
import Combine
import SwiftUI

enum MenuBarPresentation {
    static let historySymbol = "clock.arrow.circlepath"
    static let clearHistorySymbol = "trash"
    static let settingsSymbol = "gearshape"
    static let quitSymbol = "power"

    static func historyTitle(shortcut: ShortcutPreset) -> String {
        "Open Clipboard History (\(shortcut.title))"
    }

    static func monitoringTitle(isPaused: Bool) -> String {
        isPaused ? "Resume Monitoring" : "Pause Monitoring"
    }

    static func monitoringSymbol(isPaused: Bool) -> String {
        isPaused ? "play.fill" : "pause.fill"
    }

    static func canClearHistory(itemCount: Int) -> Bool {
        itemCount > 0
    }
}

@MainActor
final class ClipVaultApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var panelController: HistoryPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var historyMenuItem: NSMenuItem?
    private var showMenuBarIconSubscription: AnyCancellable?
    private var monitoringMenuItem: NSMenuItem?
    private var clearHistoryMenuItem: NSMenuItem?

    private static let statusImage: NSImage? = {
        let image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipVault")
        image?.isTemplate = true
        return image
    }()
    private static let historyMenuImage = makeMenuImage(named: MenuBarPresentation.historySymbol)
    private static let pauseMenuImage = makeMenuImage(named: MenuBarPresentation.monitoringSymbol(isPaused: false))
    private static let resumeMenuImage = makeMenuImage(named: MenuBarPresentation.monitoringSymbol(isPaused: true))
    private static let clearHistoryMenuImage = makeMenuImage(named: MenuBarPresentation.clearHistorySymbol)
    private static let settingsMenuImage = makeMenuImage(named: MenuBarPresentation.settingsSymbol)
    private static let quitMenuImage = makeMenuImage(named: MenuBarPresentation.quitSymbol)

    private static func makeMenuImage(named symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let panelController = HistoryPanelController(model: model)
        self.panelController = panelController
        model.onOpenHistory = { [weak panelController] in panelController?.show() }
        model.onCloseHistory = { [weak panelController] in panelController?.close() }
        let settingsWindowController = SettingsWindowController(model: model)
        self.settingsWindowController = settingsWindowController
        model.onOpenSettings = { [weak settingsWindowController] in settingsWindowController?.show() }
        configureMenuBar()
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func menuWillOpen(_ menu: NSMenu) {
        historyMenuItem?.title = MenuBarPresentation.historyTitle(shortcut: model.preferences.shortcut)
        let isPaused = model.preferences.monitoringPaused
        monitoringMenuItem?.title = MenuBarPresentation.monitoringTitle(isPaused: isPaused)
        monitoringMenuItem?.image = isPaused ? Self.resumeMenuImage : Self.pauseMenuImage
        clearHistoryMenuItem?.isEnabled = MenuBarPresentation.canClearHistory(itemCount: model.itemCount)
    }

    private func configureMenuBar() {
        setMenuBarIconVisible(model.preferences.showMenuBarIcon)
        showMenuBarIconSubscription = model.preferences.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] visible in
                DispatchQueue.main.async { self?.setMenuBarIconVisible(visible) }
            }
    }

    private func setMenuBarIconVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.statusImage
            item.button?.toolTip = "ClipVault"

            let menu = NSMenu()
            menu.delegate = self
            let historyItem = NSMenuItem(
                title: MenuBarPresentation.historyTitle(shortcut: model.preferences.shortcut),
                action: #selector(openHistoryFromMenu(_:)),
                keyEquivalent: ""
            )
            historyItem.image = Self.historyMenuImage
            historyMenuItem = historyItem
            menu.addItem(historyItem)

            let isPaused = model.preferences.monitoringPaused
            let monitoringItem = NSMenuItem(
                title: MenuBarPresentation.monitoringTitle(isPaused: isPaused),
                action: #selector(toggleMonitoringFromMenu(_:)),
                keyEquivalent: ""
            )
            monitoringItem.image = isPaused ? Self.resumeMenuImage : Self.pauseMenuImage
            monitoringMenuItem = monitoringItem
            menu.addItem(monitoringItem)

            let clearItem = NSMenuItem(
                title: "Clear History…",
                action: #selector(confirmClearHistoryFromMenu(_:)),
                keyEquivalent: ""
            )
            clearItem.image = Self.clearHistoryMenuImage
            clearItem.isEnabled = MenuBarPresentation.canClearHistory(itemCount: model.itemCount)
            clearHistoryMenuItem = clearItem
            menu.addItem(clearItem)

            menu.addItem(.separator())
            let settingsItem = NSMenuItem(
                title: "Settings…",
                action: #selector(showSettingsFromMenu(_:)),
                keyEquivalent: ""
            )
            settingsItem.image = Self.settingsMenuImage
            menu.addItem(settingsItem)

            let quitItem = NSMenuItem(
                title: "Quit ClipVault",
                action: #selector(quitFromMenu(_:)),
                keyEquivalent: ""
            )
            quitItem.image = Self.quitMenuImage
            menu.addItem(quitItem)

            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            historyMenuItem = nil
            monitoringMenuItem = nil
            clearHistoryMenuItem = nil
        }
    }

    @objc private func openHistoryFromMenu(_ sender: Any?) {
        model.openHistory()
    }

    @objc private func toggleMonitoringFromMenu(_ sender: Any?) {
        model.setMonitoringPaused(!model.preferences.monitoringPaused)
    }

    @objc private func confirmClearHistoryFromMenu(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This removes saved items and their local assets, including pinned items."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.clearHistory()
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        model.openSettings()
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let settingsWindow: NSWindow
        if let window {
            settingsWindow = window
        } else {
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = "ClipVault Settings"
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentView = NSHostingView(rootView: SettingsView(model: model))
            self.window = settingsWindow
        }
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class HistoryPanelController {
    private let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let historyPanel: NSPanel
        if let panel {
            historyPanel = panel
        } else {
            historyPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 590),
                styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            historyPanel.title = "ClipVault"
            historyPanel.titleVisibility = .hidden
            historyPanel.titlebarAppearsTransparent = true
            historyPanel.isFloatingPanel = true
            historyPanel.level = .floating
            historyPanel.isReleasedWhenClosed = false
            historyPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            historyPanel.contentView = NSHostingView(rootView: HistoryPanelView(model: model))
            self.panel = historyPanel
        }
        historyPanel.center()
        historyPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
    }
}
