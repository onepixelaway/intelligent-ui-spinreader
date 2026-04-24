import SwiftUI

struct ControlPanel: View {
    let highlightAnimating: Bool
    let onHighlight: () -> Void
    let onHighlightSwipeDown: () -> Void
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

    private let highlightSwipeMinDistance: CGFloat = 20
    private let highlightSwipeActivationDY: CGFloat = 30
    private let cornerRadius: CGFloat = 36

    var body: some View {
        VStack(spacing: 16) {
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
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var readerControlsRow: some View {
        HStack(spacing: 24) {
            CircularReaderButton(
                systemImage: highlightAnimating ? "checkmark" : "highlighter",
                accessibilityLabel: "Highlight",
                action: onHighlight
            )
            .scaleEffect(highlightAnimating ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: highlightAnimating)
            .highPriorityGesture(
                DragGesture(minimumDistance: highlightSwipeMinDistance)
                    .onEnded { value in
                        let dy = value.translation.height
                        let dx = value.translation.width
                        guard dy > highlightSwipeActivationDY, dy > abs(dx) else { return }
                        onHighlightSwipeDown()
                    }
            )

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

