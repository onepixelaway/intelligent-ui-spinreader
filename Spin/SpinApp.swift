import SwiftUI

@main
struct SpinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var highlightStore = HighlightStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            rootView
            .environment(highlightStore)
            .task {
                EmojiColorExtractor.shared.preloadDefaults()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                highlightStore.flush()
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SpinPlaybackPagingUITest") {
            PlaybackPagingUITestRoot()
        } else {
            EpubLibraryView()
        }
        #else
        EpubLibraryView()
        #endif
    }
}

#if DEBUG
private struct PlaybackPagingUITestRoot: View {
    private let chapters: [EpubChapter] = {
        let paragraph = Array(repeating: [
            "This paragraph exists only for the playback paging simulator test.",
            "It gives the reader enough wrapped lines to create several pages.",
            "When the test injects a spoken word from the next page, the real ScrollTextView highlight observer should advance immediately."
        ].joined(separator: " "), count: 30).joined(separator: " ")

        return [
            EpubChapter(
                id: 0,
                title: "Playback Paging Test",
                xhtmlPath: "playback-paging-test.xhtml",
                anchor: nil,
                depth: 0,
                items: [
                    .title("Playback Paging Test"),
                    .paragraph(paragraph),
                    .paragraph(paragraph)
                ]
            )
        ]
    }()

    var body: some View {
        NavigationStack {
            ScrollTextView(chapters: chapters, startingIndex: 0, bookID: "playback-paging-ui-test")
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
        }
    }
}
#endif
