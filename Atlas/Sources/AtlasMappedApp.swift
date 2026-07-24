import SwiftUI

@main
struct AtlasMappedApp: App {
    @StateObject private var appState = AppState(persistsPins: true, persistsPreferences: true)

    var body: some Scene {
        WindowGroup {
            Group {
                #if os(macOS)
                RootView()
                .frame(minWidth: 390, minHeight: 640)
                #else
                RootView()
                #endif
            }
                .environmentObject(appState)
                .preferredColorScheme(.light)
        }
        #if os(macOS)
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        #endif
    }
}
