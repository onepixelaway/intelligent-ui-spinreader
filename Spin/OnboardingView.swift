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
        withAnimation(.easeInOut(duration: 0.3)) {
            hasCompletedOnboarding = true
        }
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

private let onboardingSampleTags = ["Steve Jobs", "gratitude", "humanity"]

private enum FinishPhase {
    case idle      // normal interaction
    case sliding   // text/panel slide+fade
    case fading    // entire container fades out
}

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
    @State private var localHighlights: [Highlight] = []
    @State private var didTriggerCompletion = false
    @State private var finishPhase: FinishPhase = .idle

    @State private var panelHeight: CGFloat = 0
    @State private var tooltipVisible: Bool = false

    private let scrollPerSwipe: CGFloat = 180
    private let trackpadAdvanceThreshold: CGFloat = 80
    private let onboardingContentID = "onboarding-sample"
    private let panelBottomInset: CGFloat = 24
    private let tooltipPanelGap: CGFloat = 14

    private var actions: [PanelAction] {
        let configured = readerSettings.panelActions
        return configured.isEmpty ? PanelAction.defaults : configured
    }

    private var slideOut: Bool { finishPhase != .idle }
    private var entireFade: Bool { finishPhase == .fading }
    private var contentInteractive: Bool { finishPhase == .idle && !didTriggerCompletion }
    private var textHitTestEnabled: Bool {
        contentInteractive && step == .highlight && isHighlightMode
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            sampleTextLayer
                .offset(y: slideOut ? -200 : 0)
                .opacity(slideOut ? 0 : 1)

            tooltipLayer
                .offset(y: slideOut ? -120 : 0)
                .opacity(slideOut ? 0 : 1)
                .allowsHitTesting(false)

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
                onCancelHighlight: handleCancelHighlight,
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
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ControlPanelHeightKey.self, value: geo.size.height)
                }
            )
            .padding(.horizontal, 34)
            .padding(.bottom, panelBottomInset)
            .offset(y: slideOut ? 240 : 0)
            .opacity(slideOut ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(ControlPanelHeightKey.self) { value in
            if abs(value - panelHeight) > 0.5 {
                panelHeight = value
            }
        }
        .opacity(entireFade ? 0 : 1)
        .allowsHitTesting(contentInteractive)
        .sheet(item: $explainerURL, onDismiss: handleSheetDismissed) { item in
            SafariView(url: item.url)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    tooltipVisible = true
                }
            }
        }
    }

    @ViewBuilder
    private var tooltipLayer: some View {
        let copy = currentTooltipCopy
        let tipClearance = panelHeight + panelBottomInset + tooltipPanelGap
        TutorialTooltip(
            title: copy.title,
            subtitle: copy.subtitle,
            pointerSide: copy.pointerSide
        )
        .scaleEffect(tooltipVisible ? 1.0 : 0.85, anchor: .bottom)
        .opacity(tooltipVisible && panelHeight > 0 ? 1.0 : 0.0)
        .frame(maxWidth: .infinity, alignment: copy.bubbleAlignment)
        .padding(.horizontal, copy.bubbleHorizontalPadding)
        .padding(.bottom, tipClearance)
    }

    private struct TooltipCopy {
        let title: String
        let subtitle: String
        let pointerSide: TooltipPointerSide
        let bubbleAlignment: Alignment
        let bubbleHorizontalPadding: CGFloat
    }

    private var currentTooltipCopy: TooltipCopy {
        switch step {
        case .trackpad:
            return TooltipCopy(
                title: "Swipe to read",
                subtitle: "Drag up on the trackpad",
                pointerSide: .center,
                bubbleAlignment: .center,
                bubbleHorizontalPadding: 24
            )
        case .ai:
            return TooltipCopy(
                title: "Ask anything",
                subtitle: "Tap a button to explore",
                pointerSide: .trailing,
                bubbleAlignment: .trailing,
                bubbleHorizontalPadding: 44
            )
        case .highlight:
            return TooltipCopy(
                title: "Highlight a passage",
                subtitle: "Tap the pencil, then drag",
                pointerSide: .leading,
                bubbleAlignment: .leading,
                bubbleHorizontalPadding: 44
            )
        }
    }

    private var sampleTextLayer: some View {
        GeometryReader { geo in
            let fadeStart: CGFloat = panelHeight > 0
                ? max(0.5, (geo.size.height - panelHeight - panelBottomInset - 8) / geo.size.height)
                : 0.72
            let fadeEnd = min(1.0, fadeStart + 0.08)

            HighlightableTextView(
                text: OnboardingSample.text,
                attributedText: OnboardingSample.attributedText(
                    bodySize: readerSettings.paragraphSize,
                    fontFamily: readerSettings.fontFamily,
                    lineSpacing: readerSettings.lineSpacingPt(for: readerSettings.paragraphSize)
                ),
                itemIndex: 0,
                highlights: localHighlights,
                playbackHighlight: nil,
                isPlaybackActive: false,
                pendingHighlight: nil,
                pendingOpacity: 0.25,
                showsPendingCursor: false,
                onHighlightCreated: handleHighlightCreated,
                onHighlightRemoved: { _ in },
                onPlaybackWordTapped: { _ in },
                onEmptyTap: {}
            )
            .allowsHitTesting(textHitTestEnabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, readerSettings.margins.horizontalPadding)
            .padding(.top, 8)
            .offset(y: scrollOffset)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: fadeStart),
                        .init(color: .clear, location: fadeEnd)
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
        // Pencil toggles highlight mode. When armed, the text above becomes
        // pan-draggable for selection. The completion animation is driven by
        // an actual highlight being created — not just the mode toggle.
        guard !didTriggerCompletion else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isHighlightMode.toggle()
        }
    }

    private func handleCancelHighlight() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isHighlightMode = false
        }
    }

    private func handleHighlightCreated(_ selectedText: String, _ start: Int, _ end: Int) {
        guard step == .highlight, isHighlightMode, !didTriggerCompletion else { return }
        let color = (readerSettings.highlightColors.first ?? .yellow).rawValue
        let highlight = Highlight(
            contentID: onboardingContentID,
            text: selectedText,
            startOffset: start,
            endOffset: end,
            color: color
        )
        localHighlights.append(highlight)
        didTriggerCompletion = true
        // Brief beat so the user sees the highlight land before the dismiss kicks in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            beginCompletionAnimation()
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
}

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
    let subtitle: String
    let pointerSide: TooltipPointerSide

    private let bubbleColor = Color(red: 0.102, green: 0.157, blue: 0.275) // ~#1a2846
    private let cornerRadius: CGFloat = 12
    private let pointerWidth: CGFloat = 16
    private let pointerHeight: CGFloat = 8
    private let pointerEdgeInset: CGFloat = 22
    private let maxBubbleWidth: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.62))
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
                .frame(width: pointerWidth, height: pointerHeight)
                .padding(pointerPadEdge, pointerPadAmount)
                .offset(y: pointerHeight)
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
        case .leading, .trailing: return pointerEdgeInset
        }
    }
}

// MARK: - Sample text shared across reader screens

private enum OnboardingSample {
    static let title = "Put something back"

    static let paragraphs: [String] = [
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

    static let author = "— Steve Jobs"

    // Plain string used for both Perplexity context and HighlightableTextView's
    // offset math. Must exactly match `attributedText(...).string`.
    static let text: String = {
        var pieces: [String] = [title]
        pieces.append(contentsOf: paragraphs)
        pieces.append(author)
        return pieces.joined(separator: "\n\n")
    }()

    static func attributedText(
        bodySize: CGFloat,
        fontFamily: ReaderFontFamily,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let titleSize = bodySize + 10
        let authorSize = max(13, bodySize - 2)

        let titleFont = designedFont(size: titleSize, weight: .bold, family: fontFamily)
        let bodyFont = designedFont(size: bodySize, weight: .regular, family: fontFamily)
        let authorFont = italicFont(size: authorSize, family: fontFamily)

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineSpacing = lineSpacing
        bodyPara.paragraphSpacing = bodySize * 0.6

        let titlePara = NSMutableParagraphStyle()
        titlePara.lineSpacing = lineSpacing
        titlePara.paragraphSpacing = bodySize * 0.9

        let authorPara = NSMutableParagraphStyle()
        authorPara.lineSpacing = lineSpacing

        let bodyColor = UIColor(white: 0.92, alpha: 1.0)
        let titleColor = UIColor.white
        let authorColor = UIColor(white: 0.55, alpha: 1.0)

        let result = NSMutableAttributedString()

        result.append(NSAttributedString(string: title, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: titlePara
        ]))

        for paragraph in paragraphs {
            result.append(NSAttributedString(string: "\n\n", attributes: [
                .font: bodyFont,
                .paragraphStyle: bodyPara
            ]))
            result.append(NSAttributedString(string: paragraph, attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: bodyPara
            ]))
        }

        result.append(NSAttributedString(string: "\n\n", attributes: [
            .font: bodyFont,
            .paragraphStyle: bodyPara
        ]))
        result.append(NSAttributedString(string: author, attributes: [
            .font: authorFont,
            .foregroundColor: authorColor,
            .paragraphStyle: authorPara
        ]))

        return result
    }

    private static func designedFont(size: CGFloat, weight: UIFont.Weight, family: ReaderFontFamily) -> UIFont {
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = font.fontDescriptor.withDesign(family.uiDesign) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }

    private static func italicFont(size: CGFloat, family: ReaderFontFamily) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        var descriptor = base.fontDescriptor
        if let designed = descriptor.withDesign(family.uiDesign) {
            descriptor = designed
        }
        if let italic = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = italic
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}
