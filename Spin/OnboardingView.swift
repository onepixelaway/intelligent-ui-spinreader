import SwiftUI
import UIKit

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var showTutorial: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showTutorial {
                TutorialContainer(onFinish: finish)
                    .transition(.opacity)
            } else {
                SplashScreen(onContinue: enterTutorial)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        )
                    )
            }
        }
        .preferredColorScheme(.dark)
        .portraitOnly()
        .statusBar(hidden: true)
    }

    private func enterTutorial() {
        withAnimation(.easeInOut(duration: 0.4)) {
            showTutorial = true
        }
    }

    private func finish() {
        hasCompletedOnboarding = true
    }
}

// MARK: - Splash

private struct SplashScreen: View {
    let onContinue: () -> Void
    @State private var showButton = false

    var body: some View {
        ZStack {
            SplashDotField()
                .opacity(0.55)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Ponder")
                    .font(.system(size: 60, weight: .heavy, design: .default))
                    .foregroundColor(.white)
                    .tracking(-1)

                Text("Dig deeper on what you read")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.white.opacity(0.55))

                Spacer()
                    .frame(height: 64)

                Group {
                    if showButton {
                        Button(action: onContinue) {
                            HStack(spacing: 6) {
                                Text("Let's Go")
                                    .font(.system(size: 17, weight: .semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 18)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(height: 44)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.easeOut(duration: 0.55)) {
                    showButton = true
                }
            }
        }
    }
}

// MARK: - Splash dot animation
//
// Mirrors the TrackpadSurface pattern: a static grid of dots masks slow
// underlying animation layers. Replace the trackpad's purple glow with a soft
// white drifting glow and a slow diagonal sheen so the ambiance reads as pure
// monochrome ambiance rather than a feature surface.
private struct SplashDotField: View {
    var body: some View {
        GeometryReader { geo in
            DotMaskedAmbience(size: geo.size)
        }
    }
}

private struct DotMaskedAmbience: View {
    let size: CGSize

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)

            DriftingGlowLayer(size: size)
                .opacity(0.55)

            DiagonalSheenLayer(size: size)
                .opacity(0.22)
        }
        .mask(SplashDotMask())
    }
}

private struct SplashDotMask: View {
    private let dotDiameter: CGFloat = 2
    private let spacing: CGFloat = 18

    var body: some View {
        Canvas { ctx, size in
            let cols = max(1, Int(floor((size.width - dotDiameter) / spacing)) + 1)
            let rows = max(1, Int(floor((size.height - dotDiameter) / spacing)) + 1)
            let totalW = CGFloat(cols - 1) * spacing
            let totalH = CGFloat(rows - 1) * spacing
            let startX = (size.width - totalW) / 2
            let startY = (size.height - totalH) / 2

            for row in 0..<rows {
                for col in 0..<cols {
                    let cx = startX + CGFloat(col) * spacing
                    let cy = startY + CGFloat(row) * spacing
                    let rect = CGRect(
                        x: cx - dotDiameter / 2,
                        y: cy - dotDiameter / 2,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white))
                }
            }
        }
    }
}

private struct DriftingGlowLayer: View {
    let size: CGSize

    private let xKeyframes: [CGFloat] = [0.25, 0.75, 0.30, 0.70, 0.25]
    private let yKeyframes: [CGFloat] = [0.30, 0.60, 0.75, 0.35, 0.30]
    private let cycle: Double = 9.0

    var body: some View {
        let endRadius = sqrt(size.width * size.width + size.height * size.height) * 0.55
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: cycle)) / cycle
            let (fx, fy) = keyframePosition(phase: phase)

            RadialGradient(
                stops: [
                    .init(color: Color.white.opacity(0.95), location: 0.0),
                    .init(color: Color.white.opacity(0.40), location: 0.30),
                    .init(color: .clear, location: 0.65)
                ],
                center: UnitPoint(x: fx, y: fy),
                startRadius: 0,
                endRadius: endRadius
            )
        }
    }

    private func keyframePosition(phase: Double) -> (CGFloat, CGFloat) {
        let segments = xKeyframes.count - 1
        let scaled = phase * Double(segments)
        let i = min(Int(scaled), segments - 1)
        let localRaw = scaled - Double(i)
        let eased = easeInOut(localRaw)
        let x = xKeyframes[i] + (xKeyframes[i + 1] - xKeyframes[i]) * CGFloat(eased)
        let y = yKeyframes[i] + (yKeyframes[i + 1] - yKeyframes[i]) * CGFloat(eased)
        return (x, y)
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

private struct DiagonalSheenLayer: View {
    let size: CGSize
    private let cycle: Double = 7.0

    private static let shineStart = UnitPoint(x: 0.05, y: 0.25)
    private static let shineEnd = UnitPoint(x: 0.95, y: 0.75)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t.truncatingRemainder(dividingBy: cycle)) / cycle)

            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.40),
                            .init(color: Color.white.opacity(0.85), location: 0.5),
                            .init(color: .clear, location: 0.60),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: Self.shineStart,
                        endPoint: Self.shineEnd
                    )
                )
                .frame(width: size.width * 2, height: size.height * 2)
                .offset(
                    x: -size.width + phase * (2 * size.width),
                    y: -size.height + phase * (2 * size.height)
                )
        }
    }
}

// MARK: - Tutorial container
//
// One persistent layout for all three tutorial steps. The real ControlPanel is
// instantiated exactly once and stays mounted across step changes; only the
// instruction text above it crossfades. The Safari sheet for the AI step is
// presented from this container so it survives the step transition.

private enum TutorialStep: Hashable {
    case trackpad
    case ai
    case highlight
}

private let onboardingSampleTags = ["Walden", "Thoreau", "deliberately"]

private struct TutorialContainer: View {
    let onFinish: () -> Void
    @EnvironmentObject private var readerSettings: ReaderSettings

    @State private var step: TutorialStep = .trackpad

    @State private var scrollOffset: CGFloat = 0
    @State private var cumulativeScroll: CGFloat = 0
    @State private var didAdvanceTrackpad = false

    @State private var explainerURL: IdentifiableURL?
    @State private var aiAdvanceArmed = false

    @State private var isHighlightMode = false
    @State private var didFinish = false

    private let scrollPerSwipe: CGFloat = 180
    private let trackpadAdvanceThreshold: CGFloat = 80

    private var actions: [PanelAction] {
        let configured = readerSettings.panelActions
        return configured.isEmpty ? PanelAction.defaults : configured
    }

    var body: some View {
        VStack(spacing: 0) {
            instructionZone

            sampleTextViewport
                .padding(.top, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ControlPanel(
                isHighlightMode: isHighlightMode,
                isPlaybackMode: false,
                availableHighlightColors: readerSettings.highlightColors,
                availableHighlightEmojis: readerSettings.highlightEmojis,
                selectedHighlightColor: readerSettings.highlightColors.first ?? .yellow,
                selectedHighlightEmoji: nil,
                onHighlight: handleHighlightTap,
                onHighlightColorSelected: { _ in },
                onHighlightEmojiSelected: { _ in },
                onCancelHighlight: { isHighlightMode = false },
                onTrackpadSwipeDown: { handleSwipe(direction: -1) },
                onTrackpadSwipeUp: { handleSwipe(direction: 1) },
                isPlaybackSpeaking: false,
                isPlaybackPaused: false,
                isPlaybackPreparing: false,
                playbackSpeed: 1.0,
                playbackLevel: 0,
                onPlaybackToggle: {},
                onPlaybackSpeedTap: {},
                onPlaybackSkipBackward: {},
                onPlaybackSkipForward: {},
                onPlaybackStop: {},
                tags: onboardingSampleTags,
                actions: actions,
                onActionTap: handleActionTap,
                showQuestion: false,
                currentQuestion: "",
                isLoadingQuestion: false,
                onQuestionTap: {},
                onTagTap: { _ in }
            )
            .padding(.horizontal, 34)
            .padding(.bottom, 24)
        }
        .sheet(item: $explainerURL, onDismiss: handleSheetDismissed) { item in
            SafariView(url: item.url)
        }
    }

    private var instructionZone: some View {
        ZStack(alignment: .topLeading) {
            instructionContent(for: step)
                .id(step)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.35), value: step)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, readerSettings.margins.horizontalPadding)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func instructionContent(for step: TutorialStep) -> some View {
        let copy = Self.copy(for: step)
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text(copy.subtitle)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func copy(for step: TutorialStep) -> (title: String, subtitle: String) {
        switch step {
        case .trackpad:
            return ("Swipe to read", "Use the trackpad to scroll through your reading.")
        case .ai:
            return ("Your AI reading companion", "Tap a button to look something up.")
        case .highlight:
            return ("Tap the pencil to highlight", "Use the pencil button on the left of the control pad.")
        }
    }

    private var sampleTextViewport: some View {
        GeometryReader { geo in
            Text(OnboardingSample.text)
                .font(.system(
                    size: readerSettings.paragraphSize,
                    weight: .regular,
                    design: readerSettings.fontFamily.design
                ))
                .foregroundColor(Color(white: 0.92))
                .lineSpacing(readerSettings.lineSpacingPt(for: readerSettings.paragraphSize))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, readerSettings.margins.horizontalPadding)
                .offset(y: scrollOffset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.08),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // MARK: Callbacks

    private func handleSwipe(direction: Int) {
        let delta = CGFloat(direction) * -scrollPerSwipe
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            scrollOffset = min(0, scrollOffset + delta)
        }

        guard step == .trackpad, !didAdvanceTrackpad else { return }
        cumulativeScroll += abs(delta)
        guard cumulativeScroll >= trackpadAdvanceThreshold else { return }
        didAdvanceTrackpad = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            advance(to: .ai)
        }
    }

    private func handleActionTap(_ action: PanelAction) {
        guard step == .ai, explainerURL == nil else { return }
        let query = action.prompt + "\n\n" + OnboardingSample.text
        guard let url = perplexityURL(for: query) else { return }
        aiAdvanceArmed = true
        explainerURL = IdentifiableURL(url: url)
    }

    private func handleSheetDismissed() {
        guard aiAdvanceArmed else { return }
        aiAdvanceArmed = false
        guard step == .ai else { return }
        advance(to: .highlight)
    }

    private func handleHighlightTap() {
        // Mirror the real reader: tapping the pencil toggles highlight mode.
        // During the highlight step, the first tap also completes onboarding so
        // the user gets a brief confirmation glimpse of the mode change first.
        isHighlightMode.toggle()
        guard step == .highlight, !didFinish, isHighlightMode else { return }
        didFinish = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            onFinish()
        }
    }

    private func advance(to next: TutorialStep) {
        withAnimation(.easeInOut(duration: 0.35)) {
            step = next
        }
    }
}

// MARK: - Sample text shared across reader screens

private enum OnboardingSample {
    static let text: String = """
    I went to the woods because I wished to live deliberately, to front only the essential facts of life, and see if I could not learn what it had to teach, and not when I came to die, discover that I had not lived.

    I did not wish to live what was not life, living is so dear; nor did I wish to practise resignation, unless it was quite necessary. I wanted to live deep and suck out all the marrow of life, to live so sturdily and Spartan-like as to put to rout all that was not life, to cut a broad swath and shave close, to drive life into a corner, and reduce it to its lowest terms.

    — Henry David Thoreau, Walden
    """
}
