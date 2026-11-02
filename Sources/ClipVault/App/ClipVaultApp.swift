import SwiftUI

@main
struct ClipVaultApp: App {
    @NSApplicationDelegateAdaptor(ClipVaultApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        Settings {
            SettingsView(model: model)
        }
    }
}
