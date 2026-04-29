import Foundation
import SwiftUI
import UIKit
import Observation
import AVFoundation

enum HighlightColorChoice: String, CaseIterable, Identifiable {
    case green
    case yellow
    case blue

    var id: String { rawValue }

    var fillColor: Color {
        switch self {
        case .green:
            return Color(red: 0.42, green: 0.88, blue: 0.55)
        case .yellow:
            return Color(red: 1.0, green: 0.86, blue: 0.25)
        case .blue:
            return Color(red: 0.34, green: 0.67, blue: 1.0)
        }
    }

    var uiColor: UIColor {
        UIColor(fillColor)
    }
}

enum HighlightEmojiChoice: String, CaseIterable, Identifiable {
    case heart = "❤️"
    case thinking = "🤔"
    case exclamation = "❗"

    var id: String { rawValue }
    var emoji: String { rawValue }
}

struct Highlight: Identifiable, Codable {
    var id: UUID
    var contentID: String
    var text: String
    var startOffset: Int
    var endOffset: Int
    var color: String
    var emoji: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        contentID: String,
        text: String,
        startOffset: Int,
        endOffset: Int,
        color: String = "yellow",
        emoji: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.contentID = contentID
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.color = color
        self.emoji = emoji
        self.createdAt = createdAt
    }
}

struct PlaybackTextSegment {
    let itemIndex: Int
    let sentenceRange: NSRange
    let utteranceStartOffset: Int
    let utteranceText: String
}

struct PlaybackTextHighlight: Equatable {
    let itemIndex: Int
    let sentenceRange: NSRange
    let wordRange: NSRange?
}

struct PlaybackTextLocation {
    let itemIndex: Int
    let offset: Int
}

@MainActor
final class ReaderSpeechCoordinator: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var highlight: PlaybackTextHighlight?

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingSegments: [PlaybackTextSegment] = []
    private var activeSegment: PlaybackTextSegment?

    var isPlaybackActive: Bool {
        isSpeaking || isPaused
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(segments: [PlaybackTextSegment]) {
        stop(clearHighlight: true)
        guard !segments.isEmpty else { return }
        pendingSegments = segments
        speakNextSegment()
    }

    func togglePlayback(startingWith segments: [PlaybackTextSegment]) {
        if isSpeaking {
            pause()
            return
        }

        if isPaused {
            resume()
            return
        }

        start(segments: segments)
    }

    func pause() {
        guard isSpeaking else { return }
        if synthesizer.pauseSpeaking(at: .word) {
            isSpeaking = false
            isPaused = true
        }
    }

    func resume() {
        guard isPaused else { return }
        if synthesizer.continueSpeaking() {
            isSpeaking = true
            isPaused = false
        }
    }

    func stop(clearHighlight: Bool = true) {
        pendingSegments.removeAll()
        activeSegment = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        if clearHighlight {
            highlight = nil
        }
    }

    private func speakNextSegment() {
        guard !pendingSegments.isEmpty else {
            activeSegment = nil
            isSpeaking = false
            isPaused = false
            highlight = nil
            return
        }

        let segment = pendingSegments.removeFirst()
        activeSegment = segment
        isSpeaking = true
        isPaused = false
        highlight = PlaybackTextHighlight(
            itemIndex: segment.itemIndex,
            sentenceRange: segment.sentenceRange,
            wordRange: nil
        )

        let utterance = AVSpeechUtterance(string: segment.utteranceText)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard let activeSegment else { return }
        highlight = PlaybackTextHighlight(
            itemIndex: activeSegment.itemIndex,
            sentenceRange: activeSegment.sentenceRange,
            wordRange: NSRange(
                location: activeSegment.utteranceStartOffset + characterRange.location,
                length: characterRange.length
            )
        )
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speakNextSegment()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    }
}

extension Highlight {
    @MainActor
    var displayUIColor: UIColor {
        if let emoji {
            return EmojiColorExtractor.shared.color(for: emoji)
        }
        return HighlightColorChoice(rawValue: color)?.uiColor ?? HighlightColorChoice.yellow.uiColor
    }

    @MainActor
    var displayFillColor: Color {
        if emoji != nil {
            return Color(displayUIColor)
        }
        return HighlightColorChoice(rawValue: color)?.fillColor ?? HighlightColorChoice.yellow.fillColor
    }
}

@Observable
@MainActor
final class HighlightStore {
    private(set) var highlights: [Highlight] = []
    private var highlightsByContentID: [String: [Highlight]] = [:]
    private var pendingSaveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpinReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("highlights.json")
    }

    init() {
        load()
    }

    func highlights(for contentID: String) -> [Highlight] {
        highlightsByContentID[contentID] ?? []
    }

    func add(_ highlight: Highlight) {
        highlights.append(highlight)
        highlightsByContentID[highlight.contentID, default: []].append(highlight)
        debouncedSave()
    }

    func addBatch(_ newHighlights: [Highlight]) {
        guard !newHighlights.isEmpty else { return }
        highlights.append(contentsOf: newHighlights)
        for h in newHighlights {
            highlightsByContentID[h.contentID, default: []].append(h)
        }
        debouncedSave()
    }

    func remove(id: UUID) {
        guard let h = highlights.first(where: { $0.id == id }) else { return }
        highlightsByContentID[h.contentID]?.removeAll { $0.id == id }
        highlights.removeAll { $0.id == id }
        debouncedSave()
    }

    func removeBatch(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = highlights.filter { ids.contains($0.id) }
        let byContentID = Dictionary(grouping: removed, by: \.contentID)
        for (cid, toRemove) in byContentID {
            let removeIDs = Set(toRemove.map(\.id))
            highlightsByContentID[cid]?.removeAll { removeIDs.contains($0.id) }
        }
        highlights.removeAll { ids.contains($0.id) }
        debouncedSave()
    }

    private func rebuildIndex() {
        highlightsByContentID = Dictionary(grouping: highlights, by: \.contentID)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([Highlight].self, from: data) else { return }
        highlights = decoded
        rebuildIndex()
    }

    // Coalesces burst writes with a 300ms delay. Call flush() on app backgrounding to avoid losing in-flight mutations.
    private func debouncedSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func flush() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(highlights) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
