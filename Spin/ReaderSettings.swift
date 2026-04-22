import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore

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

func perplexityURL(for query: String) -> URL? {
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

enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case system
    case serif
    case monospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .monospaced: return "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }

    var uiDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

enum ReaderLineSpacing: String, CaseIterable, Identifiable {
    case compact
    case normal
    case relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .normal: return "Normal"
        case .relaxed: return "Relaxed"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .compact: return 1.2
        case .normal: return 1.5
        case .relaxed: return 1.8
        }
    }
}

enum ReaderMargins: String, CaseIterable, Identifiable {
    case narrow
    case normal
    case wide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .narrow: return "Narrow"
        case .normal: return "Normal"
        case .wide: return "Wide"
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .narrow: return 16
        case .normal: return 32
        case .wide: return 48
        }
    }
}

@MainActor
final class ReaderSettings: ObservableObject {
    private enum Keys {
        static let fontSize = "reader.fontSize"
        static let lineSpacing = "reader.lineSpacing"
        static let fontFamily = "reader.fontFamily"
        static let margins = "reader.margins"
        static let dimLevel = "reader.dimLevel"
        static let showAIQuestions = "reader.showAIQuestions"
    }

    @Published var fontSize: Double {
        didSet {
            guard fontSize != oldValue else { return }
            UserDefaults.standard.set(fontSize, forKey: Keys.fontSize)
        }
    }
    @Published var lineSpacing: ReaderLineSpacing {
        didSet {
            guard lineSpacing != oldValue else { return }
            UserDefaults.standard.set(lineSpacing.rawValue, forKey: Keys.lineSpacing)
        }
    }
    @Published var fontFamily: ReaderFontFamily {
        didSet {
            guard fontFamily != oldValue else { return }
            UserDefaults.standard.set(fontFamily.rawValue, forKey: Keys.fontFamily)
        }
    }
    @Published var margins: ReaderMargins {
        didSet {
            guard margins != oldValue else { return }
            UserDefaults.standard.set(margins.rawValue, forKey: Keys.margins)
        }
    }
    @Published var dimLevel: Double {
        didSet {
            guard dimLevel != oldValue else { return }
            UserDefaults.standard.set(dimLevel, forKey: Keys.dimLevel)
        }
    }
    @Published var showAIQuestions: Bool {
        didSet {
            guard showAIQuestions != oldValue else { return }
            UserDefaults.standard.set(showAIQuestions, forKey: Keys.showAIQuestions)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let storedSize = defaults.object(forKey: Keys.fontSize) as? Double
        self.fontSize = storedSize.map { min(max($0, 14), 28) } ?? 18
        self.lineSpacing = defaults.string(forKey: Keys.lineSpacing).flatMap(ReaderLineSpacing.init(rawValue:)) ?? .normal
        self.fontFamily = defaults.string(forKey: Keys.fontFamily).flatMap(ReaderFontFamily.init(rawValue:)) ?? .system
        self.margins = defaults.string(forKey: Keys.margins).flatMap(ReaderMargins.init(rawValue:)) ?? .normal
        self.dimLevel = min(max(defaults.double(forKey: Keys.dimLevel), 0), 0.7)
        self.showAIQuestions = defaults.object(forKey: Keys.showAIQuestions) as? Bool ?? true
    }

    var titleSize: CGFloat { CGFloat(fontSize) + 9 }
    var bylineSize: CGFloat { CGFloat(fontSize) + 3 }
    var paragraphSize: CGFloat { CGFloat(fontSize) }
    var blockquoteSize: CGFloat { max(12, CGFloat(fontSize) - 1) }
    var codeSize: CGFloat { max(10, CGFloat(fontSize) - 5) }
    var captionSize: CGFloat { max(10, CGFloat(fontSize) - 6) }

    func lineSpacingPt(for size: CGFloat) -> CGFloat {
        size * (lineSpacing.multiplier - 1.0) / 2
    }

    var paginatedChunkHeight: CGFloat {
        let size = paragraphSize
        let systemFontLineHeightRatio: CGFloat = 1.2
        let linesPerChunk: CGFloat = 5
        let lineToLine = size * systemFontLineHeightRatio + lineSpacingPt(for: size)
        return lineToLine * linesPerChunk
    }
}

final class HapticFeedback {
    private var engine: CHHapticEngine?
    private var lastHapticTime: CFTimeInterval = 0

    func prepare() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            try engine.start()
            self.engine = engine
        } catch {
            print("Haptic engine creation failed: \(error.localizedDescription)")
        }
    }

    func perform(speed: Double, minInterval: CFTimeInterval) {
        guard let engine else { return }
        let now = CACurrentMediaTime()
        guard now - lastHapticTime >= minInterval else { return }
        lastHapticTime = now

        do {
            let normalizedSpeed = min(abs(speed) / 10.0, 1.0)
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(0.3 + normalizedSpeed * 0.3))
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(0.3 + normalizedSpeed * 0.4))
            let duration = 0.08 - (normalizedSpeed * 0.04)
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0, duration: duration)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("Failed to play haptic pattern: \(error.localizedDescription)")
        }
    }
}
