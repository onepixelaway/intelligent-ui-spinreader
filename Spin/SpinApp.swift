import SwiftUI

@main
struct SpinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var highlightStore = HighlightStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            EpubLibraryView()
                .environment(highlightStore)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                highlightStore.flush()
            }
        }
    }
}
