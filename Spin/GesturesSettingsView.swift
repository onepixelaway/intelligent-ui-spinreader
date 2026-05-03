import SwiftUI

struct GesturesSettingsView: View {
    @EnvironmentObject var readerSettings: ReaderSettings

    var body: some View {
        List {
            pageTurningSection
            highlightSelectionSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.automatic)
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.automatic)
    }

    private var pageTurningSection: some View {
        Section {
            optionRow(title: "Swipe Up", isSelected: !readerSettings.invertTrackpadSwipe) {
                readerSettings.invertTrackpadSwipe = false
            }
            optionRow(title: "Swipe Down", isSelected: readerSettings.invertTrackpadSwipe) {
                readerSettings.invertTrackpadSwipe = true
            }
        } header: {
            Text("Page Turning")
        } footer: {
            Text("Trackpad gesture that advances to the next page.")
        }
    }

    private var highlightSelectionSection: some View {
        Section {
            optionRow(title: "Swipe Down", isSelected: !readerSettings.invertHighlightSwipe) {
                readerSettings.invertHighlightSwipe = false
            }
            optionRow(title: "Swipe Up", isSelected: readerSettings.invertHighlightSwipe) {
                readerSettings.invertHighlightSwipe = true
            }
        } header: {
            Text("Highlight Selection")
        } footer: {
            Text("Trackpad gesture that extends the highlight down the page.")
        }
    }

    private func optionRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        settingsSelectableRow(isSelected: isSelected, action: action) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }
}
