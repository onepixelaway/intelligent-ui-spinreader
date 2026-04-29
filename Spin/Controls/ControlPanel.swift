import SwiftUI

struct ControlPanel: View {
    let isHighlightMode: Bool
    let selectedHighlightColor: HighlightColorChoice
    let selectedHighlightEmoji: HighlightEmojiChoice?
    let onHighlight: () -> Void
    let onHighlightColorSelected: (HighlightColorChoice) -> Void
    let onHighlightEmojiSelected: (HighlightEmojiChoice) -> Void
    let onCancelHighlight: () -> Void
    let onTrackpadPageUp: () -> Void
    let onTrackpadPageDown: () -> Void
    let tags: [String]
    let onLearnMoreTap: () -> Void
    let onFactCheckTap: () -> Void
    let showQuestion: Bool
    let currentQuestion: String
    let isLoadingQuestion: Bool
    let onQuestionTap: () -> Void
    let onTagTap: (String) -> Void

    private let cornerRadius: CGFloat = 36
    private let highlightModeTopPadding: CGFloat = 20
    private let normalTopPadding: CGFloat = 28
    private let scaleWhenNormal: CGFloat = 0.97
    private let offsetWhenHighlight: CGFloat = 14
    private let offsetWhenNormal: CGFloat = -4

    var body: some View {
        VStack(spacing: 16) {
            if isHighlightMode {
                highlightModeOptionsRow
            }

            readerControlsRow

            tagsRow

            actionPillsRow

            if showQuestion {
                CurrentQuestionView(
                    text: currentQuestion,
                    isLoading: isLoadingQuestion,
                    onTap: onQuestionTap
                )
                .padding(.horizontal, 24)
            }
        }
        .padding(.top, isHighlightMode ? highlightModeTopPadding : normalTopPadding)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .scaleEffect(isHighlightMode ? 1.0 : scaleWhenNormal)
        .offset(y: isHighlightMode ? offsetWhenHighlight : offsetWhenNormal)
        .animation(.spring(response: 0.26, dampingFraction: 0.9), value: isHighlightMode)
    }

    private var highlightModeOptionsRow: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                ForEach(HighlightColorChoice.allCases) { color in
                    let isSelected = selectedHighlightEmoji == nil && selectedHighlightColor == color
                    Button {
                        onHighlightColorSelected(color)
                    } label: {
                        Circle()
                            .fill(color.fillColor)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(
                                        isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.16),
                                        lineWidth: isSelected ? 3 : 1
                                    )
                            )
                            .shadow(color: color.fillColor.opacity(0.45), radius: isSelected ? 8 : 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(color.rawValue.capitalized) highlight")
                }

                ForEach(HighlightEmojiChoice.allCases) { choice in
                    let isSelected = selectedHighlightEmoji == choice
                    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                    Button {
                        onHighlightEmojiSelected(choice)
                    } label: {
                        ZStack {
                            shape
                                .fill(Color.white.opacity(isSelected ? 0.18 : 0.08))
                                .frame(width: 44, height: 32)
                            Text(choice.emoji)
                                .font(.system(size: 16))
                        }
                        .overlay(
                            shape
                                .stroke(
                                    isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.16),
                                    lineWidth: isSelected ? 3 : 1
                                )
                                .frame(width: 44, height: 32)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.rawValue) emoji highlight")
                }
            }

            Spacer()

            Button(action: onCancelHighlight) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(white: 0.83))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel highlight")
        }
        .padding(.horizontal, 28)
    }

    private var readerControlsRow: some View {
        HStack(spacing: 24) {
            CircularReaderButton(
                systemImage: isHighlightMode ? "checkmark" : "highlighter",
                accessibilityLabel: isHighlightMode ? "Confirm highlight" : "Highlight",
                action: onHighlight
            )
            .scaleEffect(isHighlightMode ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHighlightMode)

            TrackpadScrollView(
                onPageUp: onTrackpadPageUp,
                onPageDown: onTrackpadPageDown
            )
            .frame(width: 140, height: 110)

            CircularReaderButton(
                systemImage: "mic.fill",
                accessibilityLabel: "Record voice note",
                action: {
                    // TODO: implement voice note capture
                }
            )
        }
        .padding(.horizontal, 24)
    }

    // Fixed row height keeps the panel's total height constant even when `tags` is empty.
    private var tagsRow: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        ReaderTagPill(text: tag) { onTagTap(tag) }
                    }
                }
                // minWidth pins HStack to viewport width when content fits, centering the pills; overflow scrolls.
                .frame(minWidth: geo.size.width, alignment: .center)
                .padding(.horizontal, 24)
            }
        }
        .frame(height: 32)
    }

    private var actionPillsRow: some View {
        HStack(spacing: 8) {
            ActionPill(title: "Learn more") {
                onLearnMoreTap()
            }
            ActionPill(title: "Is this true?") {
                onFactCheckTap()
            }
        }
        .padding(.horizontal, 24)
    }
}

