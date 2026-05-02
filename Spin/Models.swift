import Foundation
import SwiftUI
import UIKit
import Observation
import AVFoundation
import Combine

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

enum KokoroPreparationState: Equatable {
    case idle
    case awaitingDownloadConsent
    case downloading(received: Int64, total: Int64)
    case loadingModel
    case error(String)

    var isPresenting: Bool { self != .idle }
}

enum PlaybackSpeedPreference {
    static let key = "playback.speed"
    static let defaultValue = 1.0
    static let presets: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]

    static func clamped(_ value: Double) -> Double {
        min(max(value, 0.5), 4.0)
    }

    static func label(for value: Double) -> String {
        String(format: "%.1fx", value)
    }
}

@MainActor
final class ReaderSpeechCoordinator: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var isPreparingPlayback = false
    @Published private(set) var highlight: PlaybackTextHighlight?
    @Published private(set) var playbackSpeed: Double
    @Published private(set) var playbackLevel: Double = 0
    @Published var kokoroPreparation: KokoroPreparationState = .idle

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingSegments: [PlaybackTextSegment] = []
    private var playbackSegmentsSnapshot: [PlaybackTextSegment] = []
    private var activeSegmentIndex: Int?
    private var activeSegment: PlaybackTextSegment?
    private var downloadProgressObserver: AnyCancellable?

    // Kokoro pipeline: a single producer task pre-generates the next 1-2 sentences
    // while the current one plays. Buffers are scheduled on the player node as soon
    // as they're ready, so playback is seamless and the engine never goes idle.
    private static let kokoroLookahead = 2
    private struct KokoroQueuedItem {
        let index: Int
        let segment: PlaybackTextSegment
        let timings: [KokoroTokenTiming]
        let audioLevels: [Float]
    }
    private var kokoroPipelineTask: Task<Void, Never>?
    private var kokoroScheduled: [KokoroQueuedItem] = []
    // Word-level highlight scheduling for Kokoro. KokoroSwift returns per-token
    // start/end timestamps; we sleep relative to segment start to fire each one.
    private var kokoroWordHighlightTask: Task<Void, Never>?
    private var kokoroAudioLevelTask: Task<Void, Never>?
    private var kokoroSegmentStartedAt: Date?
    private var kokoroPausedElapsed: TimeInterval?

    private var currentProvider: TTSProvider {
        TTSVoicePreference.currentProvider()
    }

    private var kokoroVoiceName: String {
        TTSVoicePreference.resolvedKokoroVoice()
    }

    private var preferredVoice: AVSpeechSynthesisVoice? {
        TTSVoicePreference.resolvedVoice()
    }

    var isPlaybackActive: Bool {
        isSpeaking || isPaused
    }

    override init() {
        let savedSpeed = UserDefaults.standard.object(forKey: PlaybackSpeedPreference.key) as? Double
        self.playbackSpeed = PlaybackSpeedPreference.clamped(savedSpeed ?? PlaybackSpeedPreference.defaultValue)
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        KokoroTTSEngine.shared.setPlaybackSpeed(playbackSpeed)
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }

    func start(segments: [PlaybackTextSegment]) {
        stop(clearHighlight: true)
        guard !segments.isEmpty else { return }
        playbackSegmentsSnapshot = segments
        activeSegmentIndex = nil
        pendingSegments = segments
        switch currentProvider {
        case .apple:
            playbackLevel = 0.45
            speakNextAppleSegment()
        case .kokoro:
            startKokoroFlow()
        }
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

    func setPlaybackSpeed(_ speed: Double) {
        let clamped = PlaybackSpeedPreference.clamped(speed)
        playbackSpeed = clamped
        UserDefaults.standard.set(clamped, forKey: PlaybackSpeedPreference.key)
        KokoroTTSEngine.shared.setPlaybackSpeed(clamped)
    }

    func skipBackward15Seconds() {
        skipPlayback(seconds: -15)
    }

    func skipForward15Seconds() {
        skipPlayback(seconds: 15)
    }

    func pause() {
        guard isSpeaking else { return }
        switch currentProvider {
        case .apple:
            if synthesizer.pauseSpeaking(at: .word) {
                isSpeaking = false
                isPaused = true
                playbackLevel = 0
            }
        case .kokoro:
            if let started = kokoroSegmentStartedAt {
                kokoroPausedElapsed = Date().timeIntervalSince(started)
            }
            cancelKokoroWordHighlightTask()
            cancelKokoroAudioLevelTask()
            KokoroTTSEngine.shared.pause()
            isSpeaking = false
            isPaused = true
            playbackLevel = 0
        }
    }

    func resume() {
        guard isPaused else { return }
        switch currentProvider {
        case .apple:
            if synthesizer.continueSpeaking() {
                isSpeaking = true
                isPaused = false
                playbackLevel = 0.45
            }
        case .kokoro:
            KokoroTTSEngine.shared.resume()
            isSpeaking = true
            isPaused = false
            if let pausedElapsed = kokoroPausedElapsed,
               let active = kokoroScheduled.first {
                // Shift the virtual segment-start backwards so remaining tokens
                // fire at the same wall-clock offsets as before the pause.
                kokoroSegmentStartedAt = Date().addingTimeInterval(-pausedElapsed)
                scheduleKokoroWordHighlights(
                    timings: active.timings,
                    segment: active.segment,
                    fromOffset: pausedElapsed
                )
                scheduleKokoroAudioLevels(active.audioLevels, fromOffset: pausedElapsed)
            }
            kokoroPausedElapsed = nil
        }
    }

    func stop(clearHighlight: Bool = true) {
        resetKokoroPlaybackState()
        synthesizer.stopSpeaking(at: .immediate)
        KokoroTTSEngine.shared.stop()
        isPreparingPlayback = false
        playbackLevel = 0
        isSpeaking = false
        isPaused = false
        if clearHighlight {
            highlight = nil
        }
    }

    private func skipPlayback(seconds: TimeInterval) {
        guard !playbackSegmentsSnapshot.isEmpty,
              let activeSegmentIndex else { return }
        let targetIndex = indexForSkipping(
            from: activeSegmentIndex,
            seconds: seconds,
            segments: playbackSegmentsSnapshot
        )
        restartPlayback(at: targetIndex)
    }

    private func restartPlayback(at index: Int) {
        let segments = playbackSegmentsSnapshot
        guard segments.indices.contains(index) else { return }

        stop(clearHighlight: true)
        playbackSegmentsSnapshot = segments
        activeSegmentIndex = nil
        pendingSegments = Array(segments[index...])

        switch currentProvider {
        case .apple:
            speakNextAppleSegment()
        case .kokoro:
            startKokoroFlow()
        }
    }

    private func indexForSkipping(
        from index: Int,
        seconds: TimeInterval,
        segments: [PlaybackTextSegment]
    ) -> Int {
        guard seconds != 0, segments.indices.contains(index) else { return index }
        let targetDuration = abs(seconds)

        if seconds > 0 {
            var accumulated: TimeInterval = 0
            var candidate = index
            while candidate < segments.count - 1, accumulated < targetDuration {
                accumulated += estimatedDuration(for: segments[candidate])
                candidate += 1
            }
            return candidate
        }

        var accumulated: TimeInterval = 0
        var candidate = index
        while candidate > 0, accumulated < targetDuration {
            candidate -= 1
            accumulated += estimatedDuration(for: segments[candidate])
        }
        return candidate
    }

    private func estimatedDuration(for segment: PlaybackTextSegment) -> TimeInterval {
        let words = segment.utteranceText
            .split { $0.isWhitespace || $0.isNewline }
            .count
        let wordsPerSecond = 2.55 * max(0.5, playbackSpeed)
        return max(1.0, Double(max(words, 1)) / wordsPerSecond)
    }

    private func resetKokoroPlaybackState() {
        kokoroPipelineTask?.cancel()
        kokoroPipelineTask = nil
        cancelKokoroWordHighlightTask()
        cancelKokoroAudioLevelTask()
        kokoroSegmentStartedAt = nil
        kokoroPausedElapsed = nil
        kokoroScheduled.removeAll()
        pendingSegments.removeAll()
        playbackSegmentsSnapshot.removeAll()
        activeSegmentIndex = nil
        activeSegment = nil
        playbackLevel = 0
    }

    // MARK: - Apple path

    private func speakNextAppleSegment() {
        guard !pendingSegments.isEmpty else {
            activeSegment = nil
            isSpeaking = false
            isPaused = false
            playbackLevel = 0
            highlight = nil
            return
        }

        let nextIndex = playbackSegmentsSnapshot.count - pendingSegments.count
        let segment = pendingSegments.removeFirst()
        activeSegmentIndex = nextIndex
        activeSegment = segment
        isSpeaking = true
        isPaused = false
        highlight = PlaybackTextHighlight(
            itemIndex: segment.itemIndex,
            sentenceRange: segment.sentenceRange,
            wordRange: nil
        )

        let utterance = AVSpeechUtterance(string: segment.utteranceText)
        utterance.voice = preferredVoice ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(0.95 * playbackSpeed)
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    // MARK: - Kokoro path

    private func startKokoroFlow() {
        if !KokoroPaths.isModelReady {
            // Clean up any partial/corrupt file before prompting for re-download.
            if FileManager.default.fileExists(atPath: KokoroPaths.modelURL.path) {
                try? FileManager.default.removeItem(at: KokoroPaths.modelURL)
            }
            kokoroPreparation = .awaitingDownloadConsent
            return
        }
        prepareAndSpeakKokoro(showingSheet: false)
    }

    private func prepareAndSpeakKokoro(showingSheet: Bool) {
        if KokoroTTSEngine.shared.isReady {
            isPreparingPlayback = false
            startKokoroPipeline()
            return
        }
        if showingSheet {
            kokoroPreparation = .loadingModel
        } else {
            isPreparingPlayback = true
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await KokoroTTSEngine.shared.loadIfNeeded()
                self.isPreparingPlayback = false
                if showingSheet {
                    self.kokoroPreparation = .idle
                }
                self.startKokoroPipeline()
            } catch {
                self.isPreparingPlayback = false
                self.kokoroPreparation = .error(error.localizedDescription)
                self.stop(clearHighlight: true)
            }
        }
    }

    func confirmKokoroDownload() {
        guard case .awaitingDownloadConsent = kokoroPreparation else { return }
        kokoroPreparation = .downloading(received: 0, total: KokoroPaths.modelExpectedBytes)

        // URLSession reports progress per chunk; throttle so we don't push a
        // SwiftUI re-render for every byte the download advances.
        downloadProgressObserver = KokoroModelManager.shared.$state
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] state in
                guard let self else { return }
                if case .downloading(let received, let total) = state {
                    self.kokoroPreparation = .downloading(received: received, total: total)
                }
            }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await KokoroModelManager.shared.download()
                self.downloadProgressObserver?.cancel()
                self.downloadProgressObserver = nil
                self.prepareAndSpeakKokoro(showingSheet: true)
            } catch {
                self.downloadProgressObserver?.cancel()
                self.downloadProgressObserver = nil
                self.kokoroPreparation = .error(error.localizedDescription)
                self.stop(clearHighlight: true)
            }
        }
    }

    func cancelKokoroPreparation() {
        downloadProgressObserver?.cancel()
        downloadProgressObserver = nil
        KokoroModelManager.shared.cancel()
        kokoroPreparation = .idle
        resetKokoroPlaybackState()
        isPreparingPlayback = false
        isSpeaking = false
        isPaused = false
        highlight = nil
    }

    func dismissKokoroError() {
        if case .error = kokoroPreparation {
            kokoroPreparation = .idle
        }
    }

    #if DEBUG
    func debugSetPlaybackHighlight(_ highlight: PlaybackTextHighlight) {
        self.highlight = highlight
    }
    #endif

    private func startKokoroPipeline() {
        guard !pendingSegments.isEmpty else {
            activeSegment = nil
            isSpeaking = false
            isPaused = false
            highlight = nil
            return
        }

        kokoroPipelineTask?.cancel()
        kokoroScheduled.removeAll()
        isSpeaking = true
        isPaused = false

        let voiceName = kokoroVoiceName
        print("[Coordinator] kokoro pipeline starting (\(pendingSegments.count) segments, lookahead=\(Self.kokoroLookahead))")

        kokoroPipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Backpressure: don't generate more than `kokoroLookahead` buffers
                // ahead of the player. Slots are freed as buffers finish playing
                // (handleKokoroBufferCompleted decrements `kokoroScheduled`).
                while !Task.isCancelled, self.kokoroScheduled.count >= Self.kokoroLookahead {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if Task.isCancelled { return }
                guard !self.pendingSegments.isEmpty else { return }

                let segmentIndex = self.playbackSegmentsSnapshot.count - self.pendingSegments.count
                let segment = self.pendingSegments.removeFirst()
                let preview = String(segment.utteranceText.prefix(40))
                print("[Coordinator] kokoro pre-generating: \"\(preview)…\" (queued=\(self.kokoroScheduled.count))")

                do {
                    let (samples, timings) = try await KokoroTTSEngine.shared.generateSamples(
                        text: segment.utteranceText,
                        voiceName: voiceName
                    )
                    try Task.checkCancellation()
                    guard self.isSpeaking || self.isPaused else { return }

                    let queued = KokoroQueuedItem(
                        index: segmentIndex,
                        segment: segment,
                        timings: timings,
                        audioLevels: Self.audioLevels(for: samples)
                    )
                    let isFirstQueued = self.kokoroScheduled.isEmpty
                    self.kokoroScheduled.append(queued)
                    if isFirstQueued {
                        // This buffer is about to start playing — move highlight now.
                        self.applyKokoroHighlight(for: queued)
                    }

                    try KokoroTTSEngine.shared.play(samples: samples) { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.handleKokoroBufferCompleted()
                        }
                    }
                } catch is CancellationError {
                    print("[Coordinator] kokoro pipeline cancelled")
                    return
                } catch {
                    print("[Coordinator] kokoro pipeline failed: \(error)")
                    self.stop(clearHighlight: true)
                    return
                }
            }
        }
    }

    private func handleKokoroBufferCompleted() {
        guard !kokoroScheduled.isEmpty else { return }
        kokoroScheduled.removeFirst()

        if let next = kokoroScheduled.first {
            // The next pre-scheduled buffer is now the playing one — move highlight.
            applyKokoroHighlight(for: next)
        } else if pendingSegments.isEmpty {
            // No buffers playing and nothing left to generate — pipeline drained.
            print("[Coordinator] kokoro pipeline drained")
            cancelKokoroWordHighlightTask()
            cancelKokoroAudioLevelTask()
            kokoroSegmentStartedAt = nil
            kokoroPausedElapsed = nil
            activeSegment = nil
            isSpeaking = false
            isPaused = false
            playbackLevel = 0
            highlight = nil
        }
        // Otherwise: producer is still working on the next buffer (rare underrun).
        // Highlight will be applied when that buffer is scheduled.
    }

    private func applyKokoroHighlight(for queued: KokoroQueuedItem) {
        activeSegmentIndex = queued.index
        activeSegment = queued.segment
        highlight = PlaybackTextHighlight(
            itemIndex: queued.segment.itemIndex,
            sentenceRange: queued.segment.sentenceRange,
            wordRange: nil
        )
        cancelKokoroWordHighlightTask()
        cancelKokoroAudioLevelTask()
        kokoroSegmentStartedAt = Date()
        kokoroPausedElapsed = nil
        scheduleKokoroWordHighlights(timings: queued.timings, segment: queued.segment, fromOffset: 0)
        scheduleKokoroAudioLevels(queued.audioLevels, fromOffset: 0)
    }

    private func scheduleKokoroWordHighlights(
        timings: [KokoroTokenTiming],
        segment: PlaybackTextSegment,
        fromOffset offset: TimeInterval
    ) {
        let upcoming = timings.filter { $0.startTime >= offset }
        guard !upcoming.isEmpty,
              let segmentStart = kokoroSegmentStartedAt else { return }
        let utteranceStartOffset = segment.utteranceStartOffset
        let sentenceRange = segment.sentenceRange
        let itemIndex = segment.itemIndex
        let speed = max(0.5, playbackSpeed)

        kokoroWordHighlightTask = Task { @MainActor [weak self] in
            for timing in upcoming {
                let target = segmentStart.addingTimeInterval(timing.startTime / speed)
                let waitSeconds = target.timeIntervalSince(Date())
                if waitSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                }
                if Task.isCancelled { return }
                guard let self else { return }
                // Guard against late firings after the segment has advanced.
                guard let active = self.activeSegment,
                      active.itemIndex == itemIndex,
                      active.sentenceRange == sentenceRange else { return }
                let absoluteRange = NSRange(
                    location: utteranceStartOffset + timing.range.location,
                    length: timing.range.length
                )
                self.highlight = PlaybackTextHighlight(
                    itemIndex: itemIndex,
                    sentenceRange: sentenceRange,
                    wordRange: absoluteRange
                )
            }
        }
    }

    private func cancelKokoroWordHighlightTask() {
        kokoroWordHighlightTask?.cancel()
        kokoroWordHighlightTask = nil
    }

    private func scheduleKokoroAudioLevels(_ levels: [Float], fromOffset offset: TimeInterval) {
        guard !levels.isEmpty,
              let segmentStart = kokoroSegmentStartedAt else {
            playbackLevel = 0
            return
        }

        let speed = max(0.5, playbackSpeed)
        let sampleInterval: TimeInterval = 0.05
        let startIndex = min(levels.count - 1, max(0, Int((offset / sampleInterval).rounded(.down))))

        kokoroAudioLevelTask = Task { @MainActor [weak self] in
            for index in startIndex..<levels.count {
                let target = segmentStart.addingTimeInterval((Double(index) * sampleInterval) / speed)
                let waitSeconds = target.timeIntervalSince(Date())
                if waitSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                }
                if Task.isCancelled { return }
                let next = Double(levels[index])
                if self?.playbackLevel != next {
                    self?.playbackLevel = next
                }
            }
        }
    }

    private func cancelKokoroAudioLevelTask() {
        kokoroAudioLevelTask?.cancel()
        kokoroAudioLevelTask = nil
    }

    private static func audioLevels(for samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let sampleRate = 24_000
        let windowSize = max(1, sampleRate / 20)
        var levels: [Float] = []
        levels.reserveCapacity((samples.count / windowSize) + 1)

        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + windowSize)
            var sum: Float = 0
            for sample in samples[index..<end] {
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(max(1, end - index)))
            levels.append(min(1, rms * 8))
            index = end
        }

        return levels
    }

    // MARK: - AVSpeechSynthesizerDelegate

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
        speakNextAppleSegment()
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
