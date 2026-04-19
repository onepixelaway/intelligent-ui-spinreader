import SwiftUI
import CoreHaptics
import NaturalLanguage
@preconcurrency import OpenAI
import SafariServices

struct PortraitOnlyModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
                AppDelegate.orientationLock = .portrait
            }
    }
}

extension View {
    func portraitOnly() -> some View {
        self.modifier(PortraitOnlyModifier())
    }
}

struct ScrollWheel: View {

    @Binding var value: Double
    let onScrolled: (Double) -> Void
    
    @State private var startAngle: Double = 0
    @State private var rotation: Double = 0
    @State private var lastDelta: Double = 0
    @State private var lastMovement: Double = 0  // Track actual movement direction
    
    // Constants
    let eighthRadian = Double.pi / 6
    
    // Add haptic properties
    @State private var engine: CHHapticEngine?
    @State private var lastHapticTime: TimeInterval = 0
    @State private var rotationSpeed: Double = 0
    let hapticThreshold: TimeInterval = 0.1 // Minimum time between haptics
    
    // Function to perform the OpenAI query
    private func performOpenAIQuery() async {
        do {
            let openAI = OpenAI(apiToken: StoryText.apiKey)
            if let message = ChatQuery.ChatCompletionMessageParam(role: .user, content: "who are you") {
                //let query = ChatQuery(messages: [message], model: .gpt3_5Turbo)
                //let result = try await openAI.chats(query: query)
                //print(result) // Handle the result as needed
            } else {
                print("Failed to create message")
            }
        } catch {
            print("Failed to perform OpenAI query: \(error.localizedDescription)")
        }
    }
    
    // Initialize haptic engine
    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        
        do {
            engine = try CHHapticEngine()
            try engine?.start()
        } catch {
            print("Haptic engine creation failed: \(error.localizedDescription)")
        }
    }
    
    // Create dynamic haptic feedback based on rotation speed and direction
    private func performHapticFeedback(speed: Double) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine = engine else { return }
        
        let now = Date().timeIntervalSince1970
        guard now - lastHapticTime >= hapticThreshold else { return }
        
        do {
            let normalizedSpeed = min(abs(speed) / 10.0, 1.0) // Normalize speed to 0-1
            
            // Create dynamic haptic pattern
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity,
                                                 value: Float(0.3 + normalizedSpeed * 0.3))
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness,
                                                 value: Float(0.3 + normalizedSpeed * 0.4))
            
            // Shorter duration for faster rotations
            let duration = 0.08 - (normalizedSpeed * 0.04)
            
            let event = CHHapticEvent(eventType: .hapticTransient,
                                    parameters: [intensity, sharpness],
                                    relativeTime: 0,
                                    duration: duration)
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
            
            lastHapticTime = now
        } catch {
            print("Failed to play haptic pattern: \(error.localizedDescription)")
        }
    }
    
    var body: some View {
        ZStack {
            // Larger touch target
            Circle()
                .fill(.gray.opacity(0.06))
                .frame(width: 132, height: 132)
            
            // Outer ring of donut
            Circle()
                .stroke(.gray.opacity(0.22), lineWidth: 22)
                .frame(width: 119, height: 119)
            
            // Inner ring highlight
            Circle()
                .stroke(.white.opacity(0.17), lineWidth: 2)
                .frame(width: 99, height: 99)
            
            // Circular nib
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .offset(y: -60)
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            Task {
                await performOpenAIQuery()
            }
        }
        .onAppear(perform: prepareHaptics)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let center = CGPoint(x: 66, y: 66)
                    let currentAngle = getAngle(center: center, point: gesture.location)
                    
                    if startAngle == 0 {
                        startAngle = currentAngle
                        lastDelta = 0
                        lastMovement = 0
                    } else {
                        var delta = currentAngle - startAngle
                        
                        // Handle 360-degree boundary crossing
                        if delta > 180 {
                            delta -= 360
                        } else if delta < -180 {
                            delta += 360
                        }
                        
                        // Calculate actual movement since last update
                        let movement = delta - lastDelta
                        lastDelta = delta
                        
                        // Detect direction changes
                        if abs(movement) > 0.5 {  // Threshold to avoid tiny movements
                            lastMovement = movement
                        }
                        
                        rotation += movement
                        
                        // Determine scroll direction based on actual movement
                        let direction = lastMovement > 0 ? -1.0 : 1.0  // Reversed direction
                        
                        // Check if we've moved enough for a scroll step
                        let currentStep = floor(abs(rotation) / (eighthRadian * 180 / .pi))
                        let previousStep = floor(abs(rotation - movement) / (eighthRadian * 180 / .pi))
                        
                        if currentStep != previousStep {
                            onScrolled(direction)
                        }
                        
                        // Calculate rotation speed
                        rotationSpeed = abs(movement) / 0.016 // movement per frame
                        
                        // Add haptic feedback
                        if currentStep != previousStep {
                            performHapticFeedback(speed: rotationSpeed)
                        }
                    }
                }
                .onEnded { _ in
                    startAngle = 0
                    lastDelta = 0
                    lastMovement = 0
                    rotationSpeed = 0
                }
        )
    }
    
    private func getAngle(center: CGPoint, point: CGPoint) -> Double {
        let deltaX = point.x - center.x
        let deltaY = point.y - center.y
        let angleInRadians = atan2(deltaY, deltaX)
        let angleInDegrees = angleInRadians * (180.0 / .pi)
        return (angleInDegrees + 90.0).truncatingRemainder(dividingBy: 360.0)
    }
}

struct ScrollTextView: View {
    @State private var scrollOffset: Double = 0
    @State private var wheelRotation: Double = 0
    @StateObject private var scrollState = ScrollState()
    @State private var showTopGradient: Bool = false
    @State private var visibleParagraphs: [Int] = []
    @State private var spinCount: Int = 0
    @State private var lastAnalyzedText: String = ""
    @State private var tags: [String] = ["Tag 1", "Tag 2", "Tag 3", "Tag 4", "Tag 5"]
    @State private var currentQuestion: String = "explain this to me"
    @State private var isLoadingQuestion: Bool = false
    @State private var showExplainerWebView: Bool = false

    let story = StoryText.content
    let topPadding: CGFloat = 20

    private var paragraphs: [String] {
        story.components(separatedBy: "\n\n")
    }

    // Add this helper view for tags
    struct TagView: View {
        let text: String
        @State private var showWebView = false
        
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
                    showWebView = true
                }
                .sheet(isPresented: $showWebView) {
                    SafariView(url: URL(string: "https://www.perplexity.ai/search/new?q=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)")!)
                }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                                Text(attributedParagraph(paragraph, isHeader: index < 2))
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
                        DispatchQueue.main.async {
                            // Reduce the detection height to 60% of the text area
                            let visibleHeight = geometry.size.height * 0.65 * 0.60  // Changed from 0.85 to 0.60
                            
                            visibleParagraphs = positions.filter {
                                $0.value.intersects(CGRect(x: 0, y: 0, width: geometry.size.width, height: visibleHeight))
                            }.map { $0.key }
                            
                            // Print the visible paragraphs in the console
                            let visibleText = visibleParagraphs.map { paragraphs[$0] }
                            // print("Visible Text: \(visibleText)")
                        }
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
                
                // Top gradient
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
                .position(x: geometry.size.width/2, y: geometry.size.height * 0.075)
            }
            
            // Tags section - now separate from wheel
            VStack {
                Spacer()
                
                // Tags section
                FlowLayout(spacing: 6) {
                    ForEach(tags.prefix(8), id: \.self) { tag in
                        TagView(text: tag)
                    }
                }
                .frame(maxHeight: 70)
                .padding(.horizontal, 16)
                
                // Explain text
                Text(currentQuestion)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray.opacity(0.7))
                    .padding(.top, 4)
                    .opacity(isLoadingQuestion ? 0.5 : 1.0) // Dim while loading
                    .animation(.easeInOut(duration: 0.2), value: isLoadingQuestion)
                    .multilineTextAlignment(.center) // Center align the text
                    .frame(maxWidth: .infinity) // Ensure the text is centered within the full width
                    .onTapGesture {
                        showExplainerWebView = true
                    }
                    .sheet(isPresented: $showExplainerWebView) {
                        SafariView(url: URL(string: "https://www.perplexity.ai/search/new?q=\(currentQuestion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? currentQuestion)")!)
                    }
                
                // Scroll wheel in separate layer
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 60)
                    
                    // Scroll wheel
                    HStack {
                        Spacer()
                        ScrollWheel(value: $wheelRotation) { direction in
                            if abs(scrollState.offset) > 200 {
                                showTopGradient = true
                            }
                            scrollState.handleScroll(direction: direction)
                            
                            // Increment spin count and check for OpenAI query
                            spinCount += 1
                            if spinCount >= 2 {
                                spinCount = 0 // Reset counter
                                
                                // Get visible text
                                let visibleText = visibleParagraphs.map { paragraphs[$0] }.joined(separator: " ")
                                
                                // Only analyze if text has changed
                                if visibleText != lastAnalyzedText {
                                    lastAnalyzedText = visibleText
                                    // Call OpenAI for both tags and question
                                    Task {
                                        await analyzeVisibleText(visibleText)
                                        await performOpenAIQuery(for: visibleText)
                                    }
                                }
                            }
                        }
                        .frame(width: geometry.size.width * 0.25, height: geometry.size.width * 0.25)
                        Spacer()
                    }
                }
                .padding(.bottom, 35)
            }
        }
        .portraitOnly()
    }
    
    private func attributedParagraph(_ paragraph: String, isHeader: Bool) -> AttributedString {
        var attributed = AttributedString(paragraph)
        let range = Range<AttributedString.Index>(
            uncheckedBounds: (attributed.startIndex, attributed.endIndex)
        )
        
        if isHeader {
            let isFirstParagraph = paragraphs.first == paragraph
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
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        
        var newTags: [String] = []
        
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            if let tag = tag, tag == .personalName || tag == .placeName || tag == .organizationName {
                let name = String(text[tokenRange])
                if !newTags.contains(name) {
                    newTags.append(name)
                }
            }
            return true
        }
        
        // Update tags on main thread
        await MainActor.run {
            // Update tags array with new proper nouns
            for noun in newTags {
                if !tags.contains(noun) {
                    if let index = tags.firstIndex(where: { $0.hasPrefix("Tag ") }) {
                        tags[index] = noun
                    } else if tags.count < 5 {
                        tags.append(noun)
                    }
                }
            }
            
            // Ensure only 5 unique tags
            tags = Array(Set(tags)).prefix(5).map { $0 }
        }
        
        print("Proper Nouns: \(newTags.joined(separator: ", "))")
    }
    
    private func performOpenAIQuery(for text: String) async {
        isLoadingQuestion = true
        do {
            let openAI = OpenAI(apiToken: StoryText.apiKey)
            let prompt = "Find a short 5-10 word question you may have based on the following text: \(text)"
                
            if let message = ChatQuery.ChatCompletionMessageParam(role: .user, content: prompt) {
                let query = ChatQuery(messages: [message], model: .gpt3_5Turbo)
                let result = try await openAI.chats(query: query)
                
                if let questionText = result.choices.first?.message.content {
                    // Convert to string without type information
                    let stringContent = "\(questionText)"
                    
                    await MainActor.run {
                        currentQuestion = stringContent
                        isLoadingQuestion = false
                    }
                }
            }
        } catch {
            print("Failed to perform OpenAI query: \(error.localizedDescription)")
            await MainActor.run {
                isLoadingQuestion = false
            }
        }
    }
}

@MainActor
class ScrollState: ObservableObject {
    @Published var offset: Double = 0
    private var velocity: Double = 0
    private var lastScrollTime = Date()
    
    // Adjusted constants
    private let baseScrollSpeed: Double = 7
    private let maxVelocity: Double = 40.0
    private let deceleration: Double = 0.3    // Reduced to 1/4 of 0.98
    private let acceleration: Double = 4     // Tripled from 1.1
    
    init() {
        startMomentumTimer()
    }
    
    func handleScroll(direction: Double) {
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastScrollTime)
        lastScrollTime = now
        
        if direction * velocity > 0 && timeDelta < 0.5 {
            velocity = (velocity + direction * baseScrollSpeed) * acceleration
        } else {
            velocity = direction * baseScrollSpeed
        }
        
        velocity = min(maxVelocity, max(-maxVelocity, velocity))
        
        withAnimation(.interpolatingSpring(stiffness: 170, damping: 25)) {
            offset += velocity
        }
    }
    
    private func startMomentumTimer() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 8_333_333) // 120fps for smoother updates
                
                let now = Date()
                let timeSinceLastScroll = now.timeIntervalSince(lastScrollTime)
                
                if timeSinceLastScroll > 0.1 && abs(velocity) > 0.1 {
                    velocity *= deceleration
                    
                    withAnimation(.interpolatingSpring(stiffness: 170, damping: 25)) {
                        offset += velocity
                    }
                }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

@MainActor
struct ScrollOffsetPreferenceKey: @preconcurrency PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

struct ParagraphPositionKey: PreferenceKey {
    typealias Value = [Int: CGRect]
    
    static let defaultValue: [Int: CGRect] = [:]
    
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

#Preview {
    ScrollTextView()
}

// Add FlowLayout implementation at the end of the file, before the Preview
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
                    // Center align the current row
                    let rowWidth = currentX - spacing
                    let leftPadding = (width - rowWidth) / 2
                    for index in currentRow.indices {
                        currentRow[index].x += leftPadding
                    }
                    
                    // Start new row
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
                // Center align the last row
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

// Add SafariView near the end of the file, before the Preview
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: UIViewControllerRepresentableContext<SafariView>) -> SFSafariViewController {
        return SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: UIViewControllerRepresentableContext<SafariView>) {
    }
}
