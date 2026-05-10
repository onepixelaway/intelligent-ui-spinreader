import SwiftUI
import UIKit

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var step: OnboardingStep = .splash

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                switch step {
                case .splash:
                    SplashScreen(onContinue: { advance(to: .trackpad) })
                        .transition(screenTransition)
                case .trackpad:
                    TrackpadOnboardingScreen(onComplete: { advance(to: .ai) })
                        .transition(screenTransition)
                case .ai:
                    AIOnboardingScreen(onComplete: { advance(to: .highlight) })
                        .transition(screenTransition)
                case .highlight:
                    HighlightOnboardingScreen(onComplete: finish)
                        .transition(screenTransition)
                }
            }
        }
        .preferredColorScheme(.dark)
        .portraitOnly()
        .statusBar(hidden: true)
    }

    private var screenTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity
        )
    }

    private func advance(to next: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.4)) {
            step = next
        }
    }

    private func finish() {
        hasCompletedOnboarding = true
    }
}

private enum OnboardingStep {
    case splash
    case trackpad
    case ai
    case highlight
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

// MARK: - Sample text shared across reader screens

private enum OnboardingSample {
    static let text: String = """
    I went to the woods because I wished to live deliberately, to front only the essential facts of life, and see if I could not learn what it had to teach, and not when I came to die, discover that I had not lived.

    I did not wish to live what was not life, living is so dear; nor did I wish to practise resignation, unless it was quite necessary. I wanted to live deep and suck out all the marrow of life, to live so sturdily and Spartan-like as to put to rout all that was not life, to cut a broad swath and shave close, to drive life into a corner, and reduce it to its lowest terms.

    — Henry David Thoreau, Walden
    """
}

// MARK: - Onboarding panel helper
//
// Builds the real reader ControlPanel with neutral defaults so each tutorial
// screen can wire just the callbacks relevant to its step (trackpad swipes,
// action pill taps) while still showing the full widget — circular highlight
// and play buttons, trackpad, tag pills, and AI action pills.
private struct OnboardingControlPanel: View {
    @EnvironmentObject private var readerSettings: ReaderSettings

    var tags: [String] = []
    var onTrackpadSwipeDown: () -> Void = {}
    var onTrackpadSwipeUp: () -> Void = {}
    var onActionTap: (PanelAction) -> Void = { _ in }
    var onHighlight: () -> Void = {}

    private var actions: [PanelAction] {
        let configured = readerSettings.panelActions
        return configured.isEmpty ? PanelAction.defaults : configured
    }

    var body: some View {
        ControlPanel(
            isHighlightMode: false,
            isPlaybackMode: false,
            availableHighlightColors: readerSettings.highlightColors,
            availableHighlightEmojis: readerSettings.highlightEmojis,
            selectedHighlightColor: readerSettings.highlightColors.first ?? .yellow,
            selectedHighlightEmoji: nil,
            onHighlight: onHighlight,
            onHighlightColorSelected: { _ in },
            onHighlightEmojiSelected: { _ in },
            onCancelHighlight: {},
            onTrackpadSwipeDown: onTrackpadSwipeDown,
            onTrackpadSwipeUp: onTrackpadSwipeUp,
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
            tags: tags,
            actions: actions,
            onActionTap: onActionTap,
            showQuestion: false,
            currentQuestion: "",
            isLoadingQuestion: false,
            onQuestionTap: {},
            onTagTap: { _ in }
        )
        .padding(.horizontal, 34)
        .padding(.bottom, 24)
    }
}

private let onboardingSampleTags = ["Walden", "Thoreau", "deliberately"]

// MARK: - Screen 2: trackpad

private struct TrackpadOnboardingScreen: View {
    let onComplete: () -> Void
    @EnvironmentObject private var readerSettings: ReaderSettings

    @State private var scrollOffset: CGFloat = 0
    @State private var swipesRemaining: Int = 3
    @State private var didFireComplete = false

    private let scrollPerSwipe: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            instructionHeader

            sampleTextViewport
                .padding(.top, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            OnboardingControlPanel(
                tags: onboardingSampleTags,
                onTrackpadSwipeDown: { handleSwipe(direction: -1) },
                onTrackpadSwipeUp: { handleSwipe(direction: 1) }
            )
        }
    }

    private var instructionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Swipe to read")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text("Use the trackpad below to scroll through your reading.")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, readerSettings.margins.horizontalPadding)
        .padding(.top, 40)
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

    private func handleSwipe(direction: Int) {
        let delta = CGFloat(direction) * -scrollPerSwipe
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            scrollOffset = min(0, scrollOffset + delta)
        }
        if direction > 0 {
            swipesRemaining = max(0, swipesRemaining - 1)
        }
        guard !didFireComplete, swipesRemaining == 0 else { return }
        didFireComplete = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            onComplete()
        }
    }
}

// MARK: - Screen 4: highlight

private struct HighlightOnboardingScreen: View {
    let onComplete: () -> Void
    @EnvironmentObject private var readerSettings: ReaderSettings

    @State private var didFireComplete = false

    var body: some View {
        VStack(spacing: 0) {
            instructionHeader

            sampleText
                .padding(.top, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            OnboardingControlPanel(
                tags: onboardingSampleTags,
                onHighlight: handlePencilTap
            )
        }
    }

    private var instructionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap the pencil to highlight")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text("Use the pencil button on the left of the control pad to highlight what you're reading.")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, readerSettings.margins.horizontalPadding)
        .padding(.top, 40)
    }

    private var sampleText: some View {
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
    }

    private func handlePencilTap() {
        guard !didFireComplete else { return }
        didFireComplete = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onComplete()
        }
    }
}

// MARK: - Screen 3: AI buttons

private struct AIOnboardingScreen: View {
    let onComplete: () -> Void
    @EnvironmentObject private var readerSettings: ReaderSettings

    @State private var explainerURL: IdentifiableURL?
    @State private var didFireComplete = false

    var body: some View {
        VStack(spacing: 0) {
            instructionHeader

            sampleText
                .padding(.top, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            OnboardingControlPanel(
                tags: onboardingSampleTags,
                onActionTap: { handleTap(action: $0) }
            )
        }
        .sheet(item: $explainerURL, onDismiss: advanceIfNeeded) { item in
            SafariView(url: item.url)
        }
    }

    private var instructionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your AI reading companion")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text("These buttons unlock deeper understanding. Tap one to try it.")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, readerSettings.margins.horizontalPadding)
        .padding(.top, 40)
    }

    private var sampleText: some View {
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
    }

    private func handleTap(action: PanelAction) {
        guard explainerURL == nil else { return }
        let query = action.prompt + "\n\n" + OnboardingSample.text
        guard let url = perplexityURL(for: query) else { return }
        explainerURL = IdentifiableURL(url: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            advanceIfNeeded()
        }
    }

    private func advanceIfNeeded() {
        guard !didFireComplete else { return }
        didFireComplete = true
        onComplete()
    }
}
