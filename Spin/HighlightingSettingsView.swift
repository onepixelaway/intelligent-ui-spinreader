import SwiftUI

struct HighlightingSettingsView: View {
    @EnvironmentObject var readerSettings: ReaderSettings

    var body: some View {
        List {
            colorsSection
            emojisSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.automatic)
        .navigationTitle("Highlighting")
        .navigationBarTitleDisplayMode(.automatic)
    }

    private var colorsSection: some View {
        Section {
            ForEach(HighlightColorChoice.allCases) { color in
                let isSelected = readerSettings.highlightColors.contains(color)
                let atCap = readerSettings.highlightColors.count >= ReaderSettings.maxHighlightColors
                settingsSelectableRow(
                    isSelected: isSelected,
                    action: { toggle(color, in: \.highlightColors, minCount: 1, maxCount: ReaderSettings.maxHighlightColors) },
                    isDisabled: !isSelected && atCap
                ) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(color.fillColor)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        Text(color.label)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }
            }
        } header: {
            Text("Colors")
        } footer: {
            Text("Choose up to \(ReaderSettings.maxHighlightColors) colors to show in the highlight panel.")
        }
    }

    private var emojisSection: some View {
        Section {
            ForEach(HighlightEmojiChoice.allCases) { emoji in
                let isSelected = readerSettings.highlightEmojis.contains(emoji)
                let atCap = readerSettings.highlightEmojis.count >= ReaderSettings.maxHighlightEmojis
                settingsSelectableRow(
                    isSelected: isSelected,
                    action: { toggle(emoji, in: \.highlightEmojis, minCount: 0, maxCount: ReaderSettings.maxHighlightEmojis) },
                    isDisabled: !isSelected && atCap
                ) {
                    HStack(spacing: 12) {
                        Text(emoji.emoji)
                            .font(.system(size: 22))
                            .frame(width: 22, height: 22)
                        Text(emoji.label)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }
            }
        } header: {
            Text("Emojis")
        } footer: {
            Text("Choose up to \(ReaderSettings.maxHighlightEmojis) emojis to show in the highlight panel. Leave empty to hide them.")
        }
    }

    private func toggle<T>(
        _ item: T,
        in keyPath: ReferenceWritableKeyPath<ReaderSettings, [T]>,
        minCount: Int,
        maxCount: Int
    ) where T: CaseIterable & Equatable, T.AllCases == [T] {
        var current = readerSettings[keyPath: keyPath]
        if let idx = current.firstIndex(of: item) {
            guard current.count > minCount else { return }
            current.remove(at: idx)
        } else {
            guard current.count < maxCount else { return }
            current = T.allCases.filter { current.contains($0) || $0 == item }
        }
        readerSettings[keyPath: keyPath] = current
    }
}
