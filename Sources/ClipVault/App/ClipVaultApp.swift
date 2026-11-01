import SwiftUI

@main
struct ClipVaultApp: App {
    @NSApplicationDelegateAdaptor(ClipVaultApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        MenuBarExtra(
            isInserted: Binding(
                get: { model.preferences.showMenuBarIcon },
                set: { model.preferences.showMenuBarIcon = $0 }
            )
        ) {
            MenuBarMenuView(model: model)
        } label: {
            Label("ClipVault", systemImage: "clipboard")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}
