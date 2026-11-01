import AppKit
import SwiftUI

@MainActor
final class ClipVaultApplicationDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var panelController: HistoryPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let panelController = HistoryPanelController(model: model)
        self.panelController = panelController
        model.onOpenHistory = { [weak panelController] in panelController?.show() }
        model.onCloseHistory = { [weak panelController] in panelController?.close() }
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
