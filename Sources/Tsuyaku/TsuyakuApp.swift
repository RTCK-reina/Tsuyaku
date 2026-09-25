import SwiftUI

@main
struct TsuyakuApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 860, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
