import SwiftUI

@main
struct LumaRecodeApp: App {
    @State private var workbench = WorkspaceModel()

    var body: some Scene {
        WindowGroup("映码 · LumaRecode") {
            ContentView()
                .environment(workbench)
                .frame(minWidth: 830, minHeight: 570)
        }
        .defaultSize(width: 1120, height: 750)

        Settings {
            PreferencesView()
        }
    }
}
