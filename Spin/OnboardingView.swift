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
                    TrackpadOnboardingScreen(onComplete: { advance(to: .highlight) })
                        .transition(screenTransition)
                case .highlight:
                    HighlightOnboardingScreen(onComplete: { advance(to: .ai) })
                        .transition(screenTransition)
                case .ai:
                    AIOnboardingScreen(onComplete: finish)
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
    case highlight
    case ai
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

@MainActor
private func onboardingAttributedText(
    _ text: String,
    size: CGFloat,
    weight: UIFont.Weight = .regular,
    lineSpacing: CGFloat = 8
) -> NSAttributedString {
    let para = NSMutableParagraphStyle()
    para.lineSpacing = lineSpacing
    return NSAttributedString(string: text, attributes: [
        .font: UIFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: UIColor(white: 0.92, alpha: 1.0),
        .paragraphStyle: para
    ])
}

// MARK: - Screen 2: trackpad

private struct TrackpadOnboardingScreen: View {
    let onComplete: () -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var cumulativeScroll: CGFloat = 0
    @State private var showHint = false
    @State private var didFireComplete = false

    private let scrollPerSwipe: CGFloat = 100
    private let scrollThreshold: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            instructionHeader

            sampleTextViewport
                .padding(.top, 20)

            Spacer(minLength: 0)

            hintLabel
                .frame(height: 24)
                .padding(.bottom, 14)

            TrackpadScrollView(
                onSwipeDown: { handleSwipe(direction: -1) },
                onSwipeUp: { handleSwipe(direction: 1) }
            )
            .frame(width: 220, height: 130)
            .padding(.bottom, 48)
        }
    }

    private var instructionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Swipe to read")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text("Use the trackpad below to scroll through your reading")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 40)
    }

    private var sampleTextViewport: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Text(OnboardingSample.text)
                    .font(.system(size: 18))
                    .foregroundColor(Color(white: 0.92))
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .offset(y: scrollOffset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var hintLabel: some View {
        if showHint {
            Text("Nice! Keep going →")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func handleSwipe(direction: Int) {
        let delta = CGFloat(direction) * -scrollPerSwipe
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            scrollOffset += delta
        }
        cumulativeScroll += abs(delta)

        guard !didFireComplete, cumulativeScroll >= scrollThreshold else { return }
        didFireComplete = true
        withAnimation(.easeIn(duration: 0.35)) {
            showHint = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            onComplete()
        }
    }
}

// MARK: - Screen 3: highlight

private struct HighlightOnboardingScreen: View {
    let onComplete: () -> Void

    @State private var highlights: [Highlight] = []
    @State private var showHint = false
    @State private var didFireComplete = false

    private let sampleContentID = "onboarding.highlight"

    var body: some View {
        VStack(spacing: 0) {
            instructionHeader

            sampleTextArea
                .padding(.top, 24)
                .padding(.bottom, 24)

            hintLabel
                .frame(height: 28)
                .padding(.bottom, 48)
        }
    }

    private var instructionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hold to highlight")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text("Long-press any word to start highlighting. Drag to select a passage.")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 40)
    }

    private var sampleTextArea: some View {
        ScrollView(showsIndicators: false) {
            HighlightableTextView(
                text: OnboardingSample.text,
                attributedText: onboardingAttributedText(OnboardingSample.text, size: 18),
                itemIndex: 0,
                highlights: highlights,
                playbackHighlight: nil,
                isPlaybackActive: false,
                pendingHighlight: nil,
                pendingOpacity: 0.25,
                showsPendingCursor: false,
                onHighlightCreated: handleHighlightCreated,
                onHighlightRemoved: { id in
                    highlights.removeAll { $0.id == id }
                },
                onPlaybackWordTapped: { _ in },
                onEmptyTap: {}
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
        }
    }

    @ViewBuilder
    private var hintLabel: some View {
        if showHint {
            Text("Perfect →")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func handleHighlightCreated(text: String, start: Int, end: Int) {
        let highlight = Highlight(
            contentID: sampleContentID,
            text: text,
            startOffset: start,
            endOffset: end,
            color: HighlightColorChoice.yellow.rawValue
        )
        highlights.append(highlight)

        guard !didFireComplete else { return }
        didFireComplete = true
        withAnimation(.easeIn(duration: 0.35)) {
            showHint = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            onComplete()
        }
    }
}

// MARK: - Screen 4: AI buttons

private struct AIOnboardingScreen: View {
    let onComplete: () -> Void
    @EnvironmentObject private var readerSettings: ReaderSettings

    @State private var phase: AIPhase = .idle
    @State private var tappedAction: PanelAction?

    private enum AIPhase {
        case idle
        case thinking
        case allSet
    }

    private var actions: [PanelAction] {
        let configured = readerSettings.panelActions
        return configured.isEmpty ? PanelAction.defaults : configured
    }

    var body: some View {
        VStack(spacing: 0) {
            instructionHeader

            sampleText
                .padding(.top, 24)

            Spacer(minLength: 12)

            responseArea
                .frame(height: 80)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)

            actionPillsRow
                .padding(.bottom, 48)
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
        .padding(.horizontal, 32)
        .padding(.top, 40)
    }

    private var sampleText: some View {
        Text(OnboardingSample.text)
            .font(.system(size: 17))
            .foregroundColor(Color(white: 0.92))
            .lineSpacing(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var responseArea: some View {
        switch phase {
        case .idle:
            Color.clear
        case .thinking:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white.opacity(0.55))
                    .scaleEffect(0.85)
                Text(thinkingText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .transition(.opacity)
        case .allSet:
            Text("You're all set 🎉")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var thinkingText: String {
        if let name = tappedAction?.name {
            return "Asking AI to \(name.lowercased())…"
        }
        return "Asking AI…"
    }

    private var actionPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(actions) { action in
                    ActionPill(title: action.name) {
                        handleTap(action: action)
                    }
                    .disabled(phase != .idle)
                    .opacity(phase == .idle ? 1.0 : 0.55)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func handleTap(action: PanelAction) {
        guard phase == .idle else { return }
        tappedAction = action
        withAnimation(.easeInOut(duration: 0.3)) {
            phase = .thinking
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.45)) {
                phase = .allSet
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                onComplete()
            }
        }
    }
}
