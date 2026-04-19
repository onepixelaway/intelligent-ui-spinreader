import SwiftUI
import CoreHaptics
import NaturalLanguage
@preconcurrency import OpenAI
import QuartzCore
import SafariServices

struct PortraitOnlyModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                AppDelegate.orientationLock = .portrait
                requestPortrait()
            }
    }

    private func requestPortrait() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }
}

extension View {
    func portraitOnly() -> some View {
        self.modifier(PortraitOnlyModifier())
    }
}

private func perplexityURL(for query: String) -> URL? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    else { return nil }
    return URL(string: "https://www.perplexity.ai/search/new?q=\(encoded)")
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ScrollWheel: View {
    let onScrolled: (Double) -> Void

    @State private var startAngle: Double?
    @State private var rotation: Double = 0
    @State private var lastDelta: Double = 0
    @State private var lastDirection: Double = 0

    @State private var engine: CHHapticEngine?
    @State private var lastHapticTime: CFTimeInterval = 0

    private let stepDegrees = 30.0
    private let hapticThreshold: CFTimeInterval = 0.1

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Circle()
                    .fill(.gray.opacity(0.06))

                Circle()
                    .stroke(.gray.opacity(0.22), lineWidth: diameter * (22.0 / 132.0))
                    .padding(diameter * (13.0 / 264.0))

                Circle()
                    .stroke(.white.opacity(0.17), lineWidth: 2)
                    .padding(diameter * (33.0 / 264.0))

                Circle()
                    .fill(.white)
                    .frame(width: diameter * (22.0 / 132.0), height: diameter * (22.0 / 132.0))
                    .offset(y: -diameter * (60.0 / 132.0))
                    .rotationEffect(.degrees(rotation))
            }
            .contentShape(Circle())
            .onAppear(perform: prepareHaptics)
            .gesture(dragGesture(center: center))
        }
    }

    private func dragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let currentAngle = angle(from: center, to: gesture.location)

                guard let start = startAngle else {
                    startAngle = currentAngle
                    lastDelta = 0
                    lastDirection = 0
                    return
                }

                var delta = currentAngle - start
                if delta > 180 { delta -= 360 }
                else if delta < -180 { delta += 360 }

                let movement = delta - lastDelta
                lastDelta = delta

                if abs(movement) > 0.5 {
                    lastDirection = movement > 0 ? -1.0 : 1.0
                }

                let previousRotation = rotation
                rotation += movement

                let currentStep = floor(abs(rotation) / stepDegrees)
                let previousStep = floor(abs(previousRotation) / stepDegrees)

                if currentStep != previousStep, lastDirection != 0 {
                    onScrolled(lastDirection)
                    performHapticFeedback(speed: abs(movement) / 0.016)
                }
            }
            .onEnded { _ in
                startAngle = nil
                lastDelta = 0
                lastDirection = 0
            }
    }

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            try engine.start()
            self.engine = engine
        } catch {
            print("Haptic engine creation failed: \(error.localizedDescription)")
        }
    }

    private func performHapticFeedback(speed: Double) {
        guard let engine else { return }

        let now = CACurrentMediaTime()
        guard now - lastHapticTime >= hapticThreshold else { return }
        lastHapticTime = now

        do {
            let normalizedSpeed = min(abs(speed) / 10.0, 1.0)
            let intensity = CHHapticEventParameter(
                parameterID: .hapticIntensity,
                value: Float(0.3 + normalizedSpeed * 0.3)
            )
            let sharpness = CHHapticEventParameter(
                parameterID: .hapticSharpness,
                value: Float(0.3 + normalizedSpeed * 0.4)
            )
            let duration = 0.08 - (normalizedSpeed * 0.04)

            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [intensity, sharpness],
                relativeTime: 0,
                duration: duration
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("Failed to play haptic pattern: \(error.localizedDescription)")
        }
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let degrees = atan2(dy, dx) * (180.0 / .pi)
        return (degrees + 90.0).truncatingRemainder(dividingBy: 360.0)
    }
}

struct ScrollTextView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var scrollState = ScrollState()
    @State private var showTopGradient: Bool = false
    @State private var visibleParagraphs: [Int] = []
    @State private var spinCount: Int = 0
    @State private var lastAnalyzedText: String = ""
    @State private var tags: [String] = ["Tag 1", "Tag 2", "Tag 3", "Tag 4", "Tag 5"]
    @State private var currentQuestion: String = ""
    @State private var isLoadingQuestion: Bool = false
    @State private var explainerURL: IdentifiableURL?
    @State private var analysisTask: Task<Void, Never>?

    private let paragraphs: [String]
    private let headerCount: Int
    private let showsBackButton: Bool
    private let topPadding: CGFloat = 20
    private let maxTags = 5
    private let topGradientThreshold: CGFloat = 200

    init() {
        self.paragraphs = StoryText.content.components(separatedBy: "\n\n")
        self.headerCount = 2
        self.showsBackButton = false
    }

    init(article: Article) {
        var paras: [String] = []
        let trimmedTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { paras.append(trimmedTitle) }

        var headers = paras.count
        if let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty {
            paras.append(author)
            headers += 1
        }

        let bodyParas = article.body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        paras.append(contentsOf: bodyParas)

        self.paragraphs = paras
        self.headerCount = max(headers, 1)
        self.showsBackButton = true
    }

    struct TagView: View {
        let text: String
        @State private var sheetURL: IdentifiableURL?

        var body: some View {
            Text(text)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(Color.gray.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(14)
                .onTapGesture {
                    if let url = perplexityURL(for: text) {
                        sheetURL = IdentifiableURL(url: url)
                    }
                }
                .sheet(item: $sheetURL) { item in
                    SafariView(url: item.url)
                }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollViewReader { _ in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                                Text(attributedParagraph(paragraph, index: index))
                                    .id(index)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                                    .padding(.horizontal, 32)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear
                                                .preference(key: ParagraphPositionKey.self, value: [index: geo.frame(in: .named("scroll"))])
                                        }
                                    )
                            }
                        }
                        .padding(.top, topPadding)
                        .padding(.bottom, 100)
                        .offset(y: scrollState.offset)
                    }
                    .coordinateSpace(name: "scroll")
                    .frame(maxWidth: .infinity, maxHeight: geometry.size.height * 0.65, alignment: .top)
                    .scrollDisabled(true)
                    .onPreferenceChange(ParagraphPositionKey.self) { positions in
                        let visibleHeight = geometry.size.height * 0.65 * 0.60
                        let viewport = CGRect(x: 0, y: 0, width: geometry.size.width, height: visibleHeight)
                        visibleParagraphs = positions
                            .filter { $0.value.intersects(viewport) }
                            .map { $0.key }
                            .sorted()
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: geometry.size.height * 0.65 * 0.4)
                        .allowsHitTesting(false)
                    }
                }
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: geometry.size.height * 0.15)
                .allowsHitTesting(false)
                .opacity(showTopGradient ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showTopGradient)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.075)
            }

            VStack {
                Spacer()

                FlowLayout(spacing: 6) {
                    ForEach(tags.prefix(maxTags), id: \.self) { tag in
                        TagView(text: tag)
                    }
                }
                .frame(maxHeight: 70)
                .padding(.horizontal, 16)

                Text(currentQuestion)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray.opacity(0.7))
                    .padding(.top, 4)
                    .opacity(isLoadingQuestion ? 0.5 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: isLoadingQuestion)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        if let url = perplexityURL(for: currentQuestion) {
                            explainerURL = IdentifiableURL(url: url)
                        }
                    }
                    .sheet(item: $explainerURL) { item in
                        SafariView(url: item.url)
                    }

                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 60)

                    HStack {
                        Spacer()
                        ScrollWheel { direction in
                            showTopGradient = abs(scrollState.offset) > topGradientThreshold
                            scrollState.handleScroll(direction: direction)

                            spinCount += 1
                            if spinCount >= 2 {
                                spinCount = 0
                                handleAnalysisRequest()
                            }
                        }
                        .frame(width: geometry.size.width * 0.25, height: geometry.size.width * 0.25)
                        Spacer()
                    }
                }
                .padding(.bottom, 35)
            }

            if showsBackButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .position(x: 30, y: 30)
            }
        }
        .background(Color.black)
        .portraitOnly()
    }

    private func handleAnalysisRequest() {
        let visibleText = visibleParagraphs.map { paragraphs[$0] }.joined(separator: " ")
        guard !visibleText.isEmpty, visibleText != lastAnalyzedText else { return }
        lastAnalyzedText = visibleText

        analysisTask?.cancel()
        analysisTask = Task {
            await analyzeVisibleText(visibleText)
            guard !Task.isCancelled else { return }
            await performOpenAIQuery(for: visibleText)
        }
    }

    private func attributedParagraph(_ paragraph: String, index: Int) -> AttributedString {
        var attributed = AttributedString(paragraph)
        let range = attributed.startIndex..<attributed.endIndex

        let isHeader = index < headerCount
        if isHeader {
            let isFirstParagraph = index == 0
            let size: CGFloat = isFirstParagraph ? 28 : 22
            let weight: Font.Weight = isFirstParagraph ? .bold : .semibold
            attributed[range].font = .system(size: size, weight: weight)
        } else {
            attributed[range].font = .system(size: 19, weight: .regular)
        }

        attributed[range].foregroundColor = Color(white: 0.92, opacity: 1.0)
        return attributed
    }

    private func analyzeVisibleText(_ text: String) async {
        let extracted = extractEntities(from: text)
        guard !Task.isCancelled else { return }

        await MainActor.run {
            var merged = tags
            for entity in extracted where !merged.contains(entity) {
                if let placeholderIndex = merged.firstIndex(where: { $0.hasPrefix("Tag ") }) {
                    merged[placeholderIndex] = entity
                } else if merged.count < maxTags {
                    merged.append(entity)
                }
            }
            tags = Array(merged.prefix(maxTags))
        }
    }

    private func extractEntities(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var seen = Set<String>()
        var entities: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        let entityTypes: Set<NLTag> = [.personalName, .placeName, .organizationName]

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, tokenRange in
            if let tag, entityTypes.contains(tag) {
                let name = String(text[tokenRange])
                if seen.insert(name).inserted {
                    entities.append(name)
                }
            }
            return true
        }
        return entities
    }

    private func performOpenAIQuery(for text: String) async {
        let key = Config.openAIKey
        guard !key.isEmpty else {
            print("OpenAI API key not configured — set OPENAI_API_KEY or Info.plist OpenAIAPIKey")
            return
        }

        await MainActor.run { isLoadingQuestion = true }

        var questionText: String?
        do {
            let openAI = OpenAI(apiToken: key)
            let prompt = "Find a short 5-10 word question you may have based on the following text: \(text)"

            if let message = ChatQuery.ChatCompletionMessageParam(role: .user, content: prompt) {
                let query = ChatQuery(messages: [message], model: .gpt3_5Turbo)
                let result = try await openAI.chats(query: query)
                questionText = result.choices.first?.message.content
            }
        } catch is CancellationError {
            // Caller will set loading state on next cycle.
        } catch {
            print("Failed to perform OpenAI query: \(error.localizedDescription)")
        }

        guard !Task.isCancelled else { return }
        await MainActor.run {
            if let questionText { currentQuestion = questionText }
            isLoadingQuestion = false
        }
    }
}

@MainActor
final class ScrollState: ObservableObject {
    @Published var offset: Double = 0
    private var velocity: Double = 0
    private var lastScrollTime = CACurrentMediaTime()
    private var momentumTask: Task<Void, Never>?

    private let baseScrollSpeed: Double = 7
    private let maxVelocity: Double = 40.0
    private let deceleration: Double = 0.3
    private let acceleration: Double = 4
    private let activeFrameNanos: UInt64 = 8_333_333
    private let idleFrameNanos: UInt64 = 50_000_000
    private let momentumSpring = Animation.interpolatingSpring(stiffness: 170, damping: 25)

    init() {
        startMomentumTimer()
    }

    func handleScroll(direction: Double) {
        let now = CACurrentMediaTime()
        let timeDelta = now - lastScrollTime
        lastScrollTime = now

        if direction * velocity > 0 && timeDelta < 0.5 {
            velocity = (velocity + direction * baseScrollSpeed) * acceleration
        } else {
            velocity = direction * baseScrollSpeed
        }

        velocity = min(maxVelocity, max(-maxVelocity, velocity))

        withAnimation(momentumSpring) {
            offset += velocity
        }
    }

    private func startMomentumTimer() {
        momentumTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isIdle = abs(self.velocity) <= 0.1
                let sleepNanos = isIdle ? self.idleFrameNanos : self.activeFrameNanos
                try? await Task.sleep(nanoseconds: sleepNanos)

                let timeSinceLastScroll = CACurrentMediaTime() - self.lastScrollTime
                if timeSinceLastScroll > 0.1 && abs(self.velocity) > 0.1 {
                    self.velocity *= self.deceleration
                    withAnimation(self.momentumSpring) {
                        self.offset += self.velocity
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var orientationLock = UIInterfaceOrientationMask.portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

struct ParagraphPositionKey: PreferenceKey {
    typealias Value = [Int: CGRect]

    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return CGSize(width: proposal.width ?? 0, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)

        for row in result.rows {
            for item in row {
                let position = CGPoint(
                    x: bounds.minX + item.x,
                    y: bounds.minY + item.y
                )

                item.subview.place(
                    at: position,
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    struct FlowResult {
        var height: CGFloat = 0
        var rows: [[Item]] = []

        struct Item {
            let subview: LayoutSubview
            var size: CGSize
            var x: CGFloat
            var y: CGFloat
        }

        init(in width: CGFloat, subviews: LayoutSubviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentRow: [Item] = []
            var currentY: CGFloat = 0
            var maxRowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if currentX + size.width > width && !currentRow.isEmpty {
                    let rowWidth = currentX - spacing
                    let leftPadding = (width - rowWidth) / 2
                    for index in currentRow.indices {
                        currentRow[index].x += leftPadding
                    }

                    rows.append(currentRow)
                    currentRow = []
                    currentX = 0
                    currentY += maxRowHeight + spacing
                    maxRowHeight = 0
                }

                currentRow.append(Item(
                    subview: subview,
                    size: size,
                    x: currentX,
                    y: currentY
                ))

                currentX += size.width + spacing
                maxRowHeight = max(maxRowHeight, size.height)
            }

            if !currentRow.isEmpty {
                let rowWidth = currentX - spacing
                let leftPadding = (width - rowWidth) / 2
                for index in currentRow.indices {
                    currentRow[index].x += leftPadding
                }

                rows.append(currentRow)
                currentY += maxRowHeight
            }

            height = currentY
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

#Preview {
    ScrollTextView()
}
