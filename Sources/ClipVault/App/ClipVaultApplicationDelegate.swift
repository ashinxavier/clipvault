import AppKit
import Combine
import SwiftUI

enum MenuBarPresentation {
    static func monitoringTitle(isPaused: Bool) -> String {
        isPaused ? "Resume Monitoring" : "Pause Monitoring"
    }

    static func canClearHistory(itemCount: Int) -> Bool {
        itemCount > 0
    }
}

@MainActor
final class ClipVaultApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var panelController: HistoryPanelController?
    private var statusItem: NSStatusItem?
    private var showMenuBarIconSubscription: AnyCancellable?
    private var monitoringMenuItem: NSMenuItem?
    private var clearHistoryMenuItem: NSMenuItem?

    private static let statusImage: NSImage? = {
        let image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipVault")
        image?.isTemplate = true
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let panelController = HistoryPanelController(model: model)
        self.panelController = panelController
        model.onOpenHistory = { [weak panelController] in panelController?.show() }
        model.onCloseHistory = { [weak panelController] in panelController?.close() }
        configureMenuBar()
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func menuWillOpen(_ menu: NSMenu) {
        monitoringMenuItem?.title = MenuBarPresentation.monitoringTitle(
            isPaused: model.preferences.monitoringPaused
        )
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
            menu.addItem(NSMenuItem(
                title: "Open Clipboard History",
                action: #selector(openHistoryFromMenu(_:)),
                keyEquivalent: ""
            ))

            let monitoringItem = NSMenuItem(
                title: MenuBarPresentation.monitoringTitle(isPaused: model.preferences.monitoringPaused),
                action: #selector(toggleMonitoringFromMenu(_:)),
                keyEquivalent: ""
            )
            monitoringMenuItem = monitoringItem
            menu.addItem(monitoringItem)

            let clearItem = NSMenuItem(
                title: "Clear History…",
                action: #selector(confirmClearHistoryFromMenu(_:)),
                keyEquivalent: ""
            )
            clearItem.isEnabled = MenuBarPresentation.canClearHistory(itemCount: model.itemCount)
            clearHistoryMenuItem = clearItem
            menu.addItem(clearItem)

            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: "Settings…",
                action: #selector(showSettingsFromMenu(_:)),
                keyEquivalent: ""
            ))
            menu.addItem(NSMenuItem(
                title: "Quit ClipVault",
                action: #selector(quitFromMenu(_:)),
                keyEquivalent: ""
            ))

            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
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
