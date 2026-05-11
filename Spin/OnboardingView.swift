import SwiftUI
import UIKit

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var showTutorial: Bool = false
    @State private var showCompletionSequence: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showCompletionSequence {
                CompletionSequence(onFinish: completeOnboarding)
                    .transition(.opacity)
            } else if showTutorial {
                TutorialContainer(onFinish: beginCompletionSequence)
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

    private func beginCompletionSequence() {
        showCompletionSequence = true
    }

    private func completeOnboarding() {
        withAnimation(.easeInOut(duration: 0.3)) {
            hasCompletedOnboarding = true
        }
    }
}

// MARK: - Completion sequence

private struct CompletionSequence: View {
    let onFinish: () -> Void

    private let words = ["now", "time", "to", "read"]
    private let fadeIn: Double = 0.3
    private let hold: Double = 0.6
    private let fadeOut: Double = 0.2

    @State private var index: Int = 0
    @State private var visible: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if index < words.count {
                Text(words[index])
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundColor(.white)
                    .opacity(visible ? 1 : 0)
            }
        }
        .onAppear {
            showCurrentWord()
        }
    }

    private func showCurrentWord() {
        guard index < words.count else {
            onFinish()
            return
        }
        withAnimation(.easeIn(duration: fadeIn)) {
            visible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeIn + hold) {
            withAnimation(.easeOut(duration: fadeOut)) {
                visible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut) {
                index += 1
                showCurrentWord()
            }
        }
    }
}

// MARK: - Splash

private struct SplashScreen: View {
    let onContinue: () -> Void
    @State private var showButton = false
    @State private var visibleWordCount = 0

    private let taglineWords = ["Dig", "deeper", "on", "what", "you", "read"]
    private let taglineStartDelay: Double = 0.25
    private let taglineWordStagger: Double = 0.15

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

                HStack(spacing: 4) {
                    ForEach(Array(taglineWords.enumerated()), id: \.offset) { index, word in
                        Text(word)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(.white.opacity(0.55))
                            .opacity(index < visibleWordCount ? 1 : 0)
                    }
                }

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
            for index in taglineWords.indices {
                let delay = taglineStartDelay + Double(index) * taglineWordStagger
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeIn(duration: 0.3)) {
                        visibleWordCount = index + 1
                    }
                }
            }
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
// The tutorial IS the real ScrollTextView with Steve Jobs as the in-memory
// chapter. Every interaction — trackpad page flips, AI action pills, the
// highlight cycle — is the live reader's own behavior. Onboarding only adds a
// tooltip layer and observes a small set of events surfaced via
// `ScrollTextViewObserver` so it can advance steps.

private enum TutorialStep: Hashable {
    case trackpad
    case ai
    case highlight
}

private enum FinishPhase {
    case idle
    case sliding
    case fading
}

private struct TooltipSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct TutorialContainer: View {
    let onFinish: () -> Void
    @EnvironmentObject private var readerSettings: ReaderSettings

    @State private var step: TutorialStep = .trackpad
    @State private var highlightPhase: Int = 0
    @State private var didTriggerCompletion = false
    @State private var finishPhase: FinishPhase = .idle
    @State private var tooltipVisible = false
    @State private var tooltipSize: CGSize = .zero

    private let tooltipPanelGap: CGFloat = 14

    private var slideOut: Bool { finishPhase != .idle }
    private var entireFade: Bool { finishPhase == .fading }
    private var contentInteractive: Bool { finishPhase == .idle && !didTriggerCompletion }

    var body: some View {
        ZStack {
            ScrollTextView(
                chapters: [Self.steveJobsChapter],
                startingIndex: 0,
                bookID: Self.onboardingBookID,
                bookTitle: "Put something back",
                bookAuthor: "Steve Jobs",
                observer: ScrollTextViewObserver(
                    onTrackpadSwipe: handleTrackpadSwipe,
                    onHighlightModeChanged: handleHighlightModeChanged,
                    onHighlightCommit: handleHighlightCommit,
                    onExplainerDismissed: handleExplainerDismissed
                )
            )
            .opacity(slideOut ? 0 : 1)
            .offset(y: slideOut ? -40 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(ControlPanelAnchorsKey.self) { anchors in
            tooltipOverlay(anchors: anchors)
                .offset(y: slideOut ? -120 : 0)
                .opacity(slideOut ? 0 : 1)
                .allowsHitTesting(false)
        }
        .opacity(entireFade ? 0 : 1)
        .allowsHitTesting(contentInteractive)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    tooltipVisible = true
                }
            }
        }
    }

    // MARK: Tooltip overlay

    @ViewBuilder
    private func tooltipOverlay(anchors: [ControlPanelAnchor: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            let copy = currentTooltipCopy
            if let anchor = anchors[copy.anchor] {
                let rect = proxy[anchor]
                let pointerCenterX = pointerCenterOffset(for: copy.pointerSide)
                let bubbleCenterX = rect.midX + tooltipSize.width / 2 - pointerCenterX
                let bubbleBottomY = rect.minY - tooltipPanelGap - TutorialTooltip.pointerHeight
                let bubbleCenterY = bubbleBottomY - tooltipSize.height / 2

                TutorialTooltip(
                    title: copy.title,
                    subtitle: copy.subtitle,
                    pointerSide: copy.pointerSide
                )
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: TooltipSizeKey.self, value: g.size)
                    }
                )
                .scaleEffect(tooltipVisible ? 1.0 : 0.85, anchor: .bottom)
                .opacity(tooltipVisible && tooltipSize.width > 0 ? 1.0 : 0.0)
                .position(x: bubbleCenterX, y: bubbleCenterY)
            }
        }
        .onPreferenceChange(TooltipSizeKey.self) { newSize in
            if abs(newSize.width - tooltipSize.width) > 0.5
                || abs(newSize.height - tooltipSize.height) > 0.5 {
                tooltipSize = newSize
            }
        }
    }

    private func pointerCenterOffset(for side: TooltipPointerSide) -> CGFloat {
        switch side {
        case .leading:
            return TutorialTooltip.pointerEdgeInset + TutorialTooltip.pointerWidth / 2
        case .center:
            return tooltipSize.width / 2
        case .trailing:
            return tooltipSize.width
                - TutorialTooltip.pointerEdgeInset
                - TutorialTooltip.pointerWidth / 2
        }
    }

    private struct TooltipCopy {
        let title: String
        let subtitle: String?
        let pointerSide: TooltipPointerSide
        let anchor: ControlPanelAnchor
    }

    private var currentTooltipCopy: TooltipCopy {
        switch step {
        case .trackpad:
            return TooltipCopy(
                title: "Swipe up",
                subtitle: "Drag up on the trackpad",
                pointerSide: .center,
                anchor: .trackpad
            )
        case .ai:
            return TooltipCopy(
                title: "Dig deeper",
                subtitle: "Tap to learn more",
                pointerSide: .leading,
                anchor: .actionPillRow
            )
        case .highlight:
            switch highlightPhase {
            case 0:
                return TooltipCopy(
                    title: "Tap to highlight",
                    subtitle: nil,
                    pointerSide: .leading,
                    anchor: .highlightButton
                )
            case 1:
                return TooltipCopy(
                    title: "Swipe to select",
                    subtitle: nil,
                    pointerSide: .center,
                    anchor: .trackpad
                )
            default:
                return TooltipCopy(
                    title: "Tap to finish",
                    subtitle: nil,
                    pointerSide: .leading,
                    anchor: .highlightButton
                )
            }
        }
    }

    // MARK: Observer callbacks

    private func handleTrackpadSwipe(isHighlightMode: Bool) {
        guard contentInteractive else { return }
        switch step {
        case .trackpad:
            guard !isHighlightMode else { return }
            advance(to: .ai)
        case .highlight:
            guard isHighlightMode, highlightPhase == 1 else { return }
            advanceHighlightPhase(to: 2)
        case .ai:
            return
        }
    }

    private func handleHighlightModeChanged(_ isHighlightMode: Bool) {
        guard contentInteractive,
              step == .highlight,
              highlightPhase == 0,
              isHighlightMode else { return }
        advanceHighlightPhase(to: 1)
    }

    private func handleHighlightCommit() {
        guard contentInteractive,
              step == .highlight,
              highlightPhase == 2,
              !didTriggerCompletion else { return }
        didTriggerCompletion = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            beginCompletionAnimation()
        }
    }

    private func handleExplainerDismissed() {
        guard contentInteractive, step == .ai else { return }
        advance(to: .highlight)
    }

    // MARK: Step transitions and completion

    private func advance(to next: TutorialStep) {
        withAnimation(.easeOut(duration: 0.2)) {
            tooltipVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.easeInOut(duration: 0.3)) {
                step = next
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    tooltipVisible = true
                }
            }
        }
    }

    private func advanceHighlightPhase(to next: Int) {
        withAnimation(.easeOut(duration: 0.2)) {
            tooltipVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.easeInOut(duration: 0.3)) {
                highlightPhase = next
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    tooltipVisible = true
                }
            }
        }
    }

    private func beginCompletionAnimation() {
        withAnimation(.easeOut(duration: 0.55)) {
            finishPhase = .sliding
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeIn(duration: 0.3)) {
                finishPhase = .fading
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onFinish()
            }
        }
    }

    // MARK: Steve Jobs in-memory chapter

    private static let onboardingBookID = "onboarding-put-something-back"

    private static let steveJobsBody: [String] = [
        "I grow little of the food I eat, and of the little I do grow I did not breed or perfect the seeds.",
        "I do not make any of my own clothing.",
        "I speak a language I did not invent or refine.",
        "I did not discover the mathematics I use.",
        "I am protected by freedoms and laws I did not conceive of or legislate, and do not enforce or adjudicate.",
        "I am moved by music I did not create myself.",
        "When I needed medical attention, I was helpless to help myself survive.",
        "I did not invent the transistor, the microprocessor, object oriented programming, or most of the technology I work with.",
        "I love and admire my species, living and dead, and am totally dependent on them for my life and well being."
    ]

    private static let steveJobsChapter: EpubChapter = {
        var items: [ScrollTextView.ReadableItem] = [.title("Put something back")]
        items.append(contentsOf: steveJobsBody.map { .paragraph($0) })
        items.append(.byline("— Steve Jobs"))
        return EpubChapter(
            id: 0,
            title: "Put something back",
            xhtmlPath: "onboarding-put-something-back.xhtml",
            anchor: nil,
            depth: 0,
            items: items
        )
    }()
}

// MARK: - Tooltip view (unchanged styling, used by TutorialContainer)

private enum TooltipPointerSide {
    case leading, center, trailing
}

private struct TooltipPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct TutorialTooltip: View {
    let title: String
    let subtitle: String?
    let pointerSide: TooltipPointerSide

    private let bubbleColor = Color(red: 0.102, green: 0.157, blue: 0.275) // ~#1a2846
    private let cornerRadius: CGFloat = 12
    static let pointerWidth: CGFloat = 16
    static let pointerHeight: CGFloat = 8
    static let pointerEdgeInset: CGFloat = 22
    private let maxBubbleWidth: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.62))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(bubbleColor)
        )
        .overlay(alignment: pointerOverlayAlignment) {
            TooltipPointer()
                .fill(bubbleColor)
                .frame(width: Self.pointerWidth, height: Self.pointerHeight)
                .padding(pointerPadEdge, pointerPadAmount)
                .offset(y: Self.pointerHeight)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
    }

    private var pointerOverlayAlignment: Alignment {
        switch pointerSide {
        case .leading: return .bottomLeading
        case .center: return .bottom
        case .trailing: return .bottomTrailing
        }
    }

    private var pointerPadEdge: Edge.Set {
        switch pointerSide {
        case .leading: return .leading
        case .center: return []
        case .trailing: return .trailing
        }
    }

    private var pointerPadAmount: CGFloat {
        switch pointerSide {
        case .center: return 0
        case .leading, .trailing: return Self.pointerEdgeInset
        }
    }
}
