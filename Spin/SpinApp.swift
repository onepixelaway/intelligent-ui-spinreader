import SwiftUI

@main
struct SpinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var highlightStore = HighlightStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(highlightStore)
        }
    }
}
