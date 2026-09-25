import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            TabView(selection: $state.selectedTab) {
                LiveView()
                    .tabItem { Label("ライブ", systemImage: "waveform") }
                    .tag(0)
                RecordingsView()
                    .tabItem { Label("録音・解析", systemImage: "doc.text.magnifyingglass") }
                    .tag(1)
                SettingsView()
                    .tabItem { Label("設定", systemImage: "gearshape") }
                    .tag(2)
            }

            // Invisible host for translation pairs whose packs need download.
            TranslationSessionsHost(bridge: state.translationBridge)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
