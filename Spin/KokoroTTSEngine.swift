import Foundation
import AVFoundation
import Combine
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// Per-token timing extracted from KokoroSwift's MToken array. The range is
/// relative to the utterance text (UTF-16 offsets) — callers add the segment's
/// utterance offset to get absolute positions in the item text.
struct KokoroTokenTiming: Sendable {
    let range: NSRange
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// Owns the model + voices and runs synthesis off the main actor.
/// Marked @unchecked Sendable so we can pass it across actor boundaries —
/// generateAudio is invoked serially via an actor-owned task queue.
final class KokoroSession: @unchecked Sendable {
    let kokoroTTS: KokoroTTS
    let voices: [String: MLXArray]

    // Bound MLX's buffer pool so iOS jetsam doesn't kill the app after a few
    // sentences. Without this, intermediate inference tensors accumulate in the
    // cache and footprint grows monotonically. 32 MB is well under iOS limits
    // and benchmarks show negligible perf hit vs unbounded.
    private static let mlxCacheLimitBytes = 32 * 1024 * 1024

    init(modelURL: URL, voicesURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw NSError(domain: "KokoroSession", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Kokoro model file missing at \(modelURL.path)"])
        }
        // MLX.loadArrays only accepts `.safetensors`; anything else triggers a `try!`
        // assertion deep inside KokoroSwift's WeightLoader. Reject up front with a real error.
        guard modelURL.pathExtension == "safetensors" else {
            try? FileManager.default.removeItem(at: modelURL)
            throw NSError(domain: "KokoroSession", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Kokoro model must be a .safetensors file (got .\(modelURL.pathExtension)). Cached file removed; re-download required."])
        }
        guard FileManager.default.fileExists(atPath: voicesURL.path) else {
            throw NSError(domain: "KokoroSession", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "voices.npz missing at \(voicesURL.path)"])
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        // Guard against partially downloaded / corrupt files; WeightLoader crashes on these.
        let minExpectedBytes: Int64 = 100_000_000
        guard fileSize >= minExpectedBytes else {
            try? FileManager.default.removeItem(at: modelURL)
            throw NSError(domain: "KokoroSession", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Kokoro model file is incomplete (\(fileSize) bytes). Re-download required."])
        }
        MLX.GPU.set(cacheLimit: Self.mlxCacheLimitBytes)
        self.kokoroTTS = KokoroTTS(modelPath: modelURL, g2p: .misaki)
        self.voices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
        if voices.isEmpty {
            throw NSError(domain: "KokoroSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load voices.npz"])
        }
        let snap = MLX.GPU.snapshot()
        print("[KokoroSession] loaded — active=\(snap.activeMemory / 1024 / 1024)MB cache=\(snap.cacheMemory / 1024 / 1024)MB cacheLimit=\(MLX.GPU.cacheLimit / 1024 / 1024)MB")
    }

    func generate(text: String, voiceName: String) throws -> ([Float], [KokoroTokenTiming]) {
        let key = voiceName + ".npy"
        guard let voiceArray = voices[key] else {
            throw NSError(domain: "KokoroSession", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown voice: \(voiceName)"])
        }
        let language: Language = (voiceName.first == "a") ? .enUS : .enGB
        // Reclaim cached intermediates from any prior inference before we start
        // the next one — this keeps peak footprint flat across many sentences.
        defer { MLX.GPU.clearCache() }
        let before = MLX.GPU.snapshot()
        let (samples, tokens) = try kokoroTTS.generateAudio(
            voice: voiceArray,
            language: language,
            text: text
        )
        let after = MLX.GPU.snapshot()
        print("[KokoroSession] generated samples=\(samples.count) active \(before.activeMemory / 1024 / 1024)→\(after.activeMemory / 1024 / 1024)MB cache \(before.cacheMemory / 1024 / 1024)→\(after.cacheMemory / 1024 / 1024)MB peak=\(after.peakMemory / 1024 / 1024)MB")

        let timings: [KokoroTokenTiming] = (tokens ?? []).compactMap { token in
            guard let start = token.start_ts, let end = token.end_ts else { return nil }
            let nsRange = NSRange(token.tokenRange, in: text)
            guard nsRange.length > 0 else { return nil }
            return KokoroTokenTiming(range: nsRange, startTime: start, endTime: end)
        }
        return (samples, timings)
    }
}

@MainActor
final class KokoroTTSEngine: ObservableObject {
    static let shared = KokoroTTSEngine()

    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var session: KokoroSession?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var didConnectPlayer = false
    // True when the user has paused playback. While paused, scheduleBuffer must not
    // trigger an implicit play() — otherwise queueing a pre-generated next-sentence
    // buffer would silently un-pause the player.
    private var playerIsPaused = false
    private var playbackSpeed: Float = 1.0

    private init() {
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
    }

    var isReady: Bool { isLoaded && session != nil }

    func loadIfNeeded() async throws {
        if isLoaded { return }
        if isLoading {
            // Wait until loading flips off
            while isLoading { try await Task.sleep(nanoseconds: 100_000_000) }
            if isLoaded { return }
        }

        // Drop any model file from earlier builds (e.g. .pth) — MLX can only read .safetensors.
        KokoroPaths.purgeLegacyModelFiles()

        guard KokoroPaths.isModelReady else {
            // Drop any partial/corrupt file so the next download starts clean.
            if FileManager.default.fileExists(atPath: KokoroPaths.modelURL.path) {
                try? FileManager.default.removeItem(at: KokoroPaths.modelURL)
            }
            throw NSError(domain: "KokoroTTSEngine", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Model file not found. Download required."])
        }
        guard let voicesURL = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
            throw NSError(domain: "KokoroTTSEngine", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "voices.npz missing from bundle"])
        }

        isLoading = true
        loadError = nil
        let modelURL = KokoroPaths.modelURL
        print("[KokoroTTSEngine] loading modelURL=\(modelURL.path) voicesURL=\(voicesURL.path)")

        do {
            let session: KokoroSession = try await Task.detached(priority: .userInitiated) {
                try KokoroSession(modelURL: modelURL, voicesURL: voicesURL)
            }.value
            self.session = session
            self.isLoaded = true
            self.isLoading = false
        } catch {
            print("[KokoroTTSEngine] load failed: \(error)")
            self.loadError = error.localizedDescription
            self.isLoading = false
            throw error
        }
    }

    func generateSamples(text: String, voiceName: String) async throws -> ([Float], [KokoroTokenTiming]) {
        if !isLoaded { try await loadIfNeeded() }
        guard let session else {
            throw NSError(domain: "KokoroTTSEngine", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "Engine not loaded"])
        }
        return try await Task.detached(priority: .userInitiated) {
            try session.generate(text: text, voiceName: voiceName)
        }.value
    }

    func play(samples: [Float], onCompletion: @escaping @Sendable () -> Void) throws {
        guard !samples.isEmpty else {
            // Nothing to play — fire completion immediately so the loop advances.
            onCompletion()
            return
        }
        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "KokoroTTSEngine", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create AVAudioFormat"])
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "KokoroTTSEngine", code: 31,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate audio buffer"])
        }
        buffer.frameLength = buffer.frameCapacity
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: src.count)
                }
            }
        }

        if !didConnectPlayer {
            timePitch.rate = playbackSpeed
            timePitch.pitch = 0
            audioEngine.connect(playerNode, to: timePitch, format: format)
            audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
            didConnectPlayer = true
        }
        if !audioEngine.isRunning {
            try audioEngine.start()
        }

        print("[KokoroTTSEngine] scheduling buffer frames=\(buffer.frameLength) engineRunning=\(audioEngine.isRunning) playerPlaying=\(playerNode.isPlaying) paused=\(playerIsPaused)")
        // .dataPlayedBack fires when the audio physically finishes coming out of the
        // device — which is the exact moment buffer N+1 starts to play, so it's the
        // right signal for advancing the highlight.
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            onCompletion()
        }
        if !playerIsPaused && !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func pause() {
        playerIsPaused = true
        if playerNode.isPlaying {
            playerNode.pause()
        }
    }

    func resume() {
        guard playerIsPaused else { return }
        playerIsPaused = false
        if audioEngine.isRunning && !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = Float(PlaybackSpeedPreference.clamped(speed))
        timePitch.rate = playbackSpeed
    }

    func stop() {
        playerNode.stop()
        playerIsPaused = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        didConnectPlayer = false
    }

    func unload() {
        stop()
        session = nil
        isLoaded = false
        isLoading = false
        loadError = nil
    }
}
