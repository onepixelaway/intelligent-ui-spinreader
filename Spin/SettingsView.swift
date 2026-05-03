import SwiftUI
import AVFoundation

enum TTSProvider: String, CaseIterable, Identifiable {
    case apple
    case kokoro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .kokoro: return "Kokoro"
        }
    }

    var subtitle: String {
        switch self {
        case .apple: return "Built-in iOS voices"
        case .kokoro: return "Neural TTS · ~312 MB download"
        }
    }
}

enum TTSPreferenceKeys {
    static let provider = "ttsProvider"
    static let voiceIdentifier = "ttsVoiceIdentifier"
    static let kokoroVoice = "ttsKokoroVoice"
    static let voiceLanguage = "en-US"
}

// MARK: - Settings Hub

struct SettingsView: View {
    var body: some View {
        List {
            Section {
                settingsCategory(
                    icon: "waveform",
                    iconColor: .blue,
                    title: "Audio Narration",
                    destination: AudioNarrationSettingsView()
                )
                settingsCategory(
                    icon: "sparkles",
                    iconColor: .purple,
                    title: "AI Actions",
                    destination: PanelActionsSettingsView()
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.automatic)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.automatic)
    }

    @ViewBuilder
    private func settingsCategory<Destination: View>(
        icon: String,
        iconColor: Color,
        title: String,
        destination: Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconColor)
                        .frame(width: 29, height: 29)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Audio Narration Settings

struct AudioNarrationSettingsView: View {
    @AppStorage(TTSPreferenceKeys.provider) private var providerRaw: String = TTSProvider.apple.rawValue
    @AppStorage(TTSPreferenceKeys.voiceIdentifier) private var voiceIdentifier: String = ""
    @AppStorage(TTSPreferenceKeys.kokoroVoice) private var kokoroVoice: String = KokoroVoiceCatalog.defaultVoice
    @State private var isKokoroModelDownloaded = KokoroPaths.isModelDownloaded
    @State private var showDeleteModelConfirmation = false
    @State private var modelDeleteError: String?

    private let voices: [AVSpeechSynthesisVoice] = AudioNarrationSettingsView.loadEnglishVoices()

    private var selectedProvider: TTSProvider {
        TTSProvider(rawValue: providerRaw) ?? .apple
    }

    var body: some View {
        List {
            providerSection
            if selectedProvider == .apple {
                voiceSection
            } else {
                kokoroVoiceSection
                kokoroModelSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.automatic)
        .navigationTitle("Audio Narration")
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear {
            refreshKokoroModelState()
        }
        .confirmationDialog(
            "Delete Kokoro model?",
            isPresented: $showDeleteModelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                deleteKokoroModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The neural model will be removed from this device. Kokoro will ask to download it again the next time you play narration.")
        }
        .alert("Couldn't Delete Model", isPresented: Binding(
            get: { modelDeleteError != nil },
            set: { if !$0 { modelDeleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(modelDeleteError ?? "")
        }
    }

    private var providerSection: some View {
        Section {
            ForEach(TTSProvider.allCases) { provider in
                Button {
                    providerRaw = provider.rawValue
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(provider.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if providerRaw == provider.rawValue {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("Choose the engine used by the Play button in the reader.")
        }
    }

    private var voiceSection: some View {
        Section {
            ForEach(voiceQualityGroups, id: \.title) { group in
                ForEach(group.voices, id: \.identifier) { voice in
                    Button {
                        voiceIdentifier = voice.identifier
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(qualityLabel(for: voice.quality))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isSelected(voice) {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Apple Voice")
        } footer: {
            Text("Showing English voices available on this device.")
        }
    }

    private var kokoroVoiceSection: some View {
        Section {
            ForEach(KokoroVoiceCatalog.grouped, id: \.0) { group in
                ForEach(group.1) { voice in
                    Button {
                        kokoroVoice = voice.name
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.displayName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text("\(group.0) · \(voice.name)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if voice.name == kokoroVoice {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Kokoro Voice")
        }
    }

    private var kokoroModelSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Neural Model")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(isKokoroModelDownloaded
                         ? "Downloaded · ~312 MB"
                         : "Not downloaded · downloads on first Play")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isKokoroModelDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if isKokoroModelDownloaded {
                Button(role: .destructive) {
                    showDeleteModelConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete Downloaded Model")
                        Spacer()
                    }
                    .font(.body)
                    .contentShape(Rectangle())
                }
            }
        } header: {
            Text("Kokoro Model")
        } footer: {
            Text("Deleting the model frees local storage. Your selected Kokoro voice is kept.")
        }
    }

    private var voiceQualityGroups: [(title: String, voices: [AVSpeechSynthesisVoice])] {
        let premium = voices.filter { $0.quality == .premium }
        let enhanced = voices.filter { $0.quality == .enhanced }
        let standard = voices.filter { $0.quality != .premium && $0.quality != .enhanced }
        var groups: [(String, [AVSpeechSynthesisVoice])] = []
        if !premium.isEmpty { groups.append(("Premium", premium)) }
        if !enhanced.isEmpty { groups.append(("Enhanced", enhanced)) }
        if !standard.isEmpty { groups.append(("Default", standard)) }
        return groups
    }

    private func isSelected(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if voiceIdentifier.isEmpty {
            return voice.identifier == TTSVoicePreference.bestVoice()?.identifier
        }
        return voice.identifier == voiceIdentifier
    }

    private func qualityLabel(for quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }

    private func refreshKokoroModelState() {
        isKokoroModelDownloaded = KokoroPaths.isModelDownloaded
    }

    private func deleteKokoroModel() {
        do {
            KokoroTTSEngine.shared.unload()
            try KokoroModelManager.shared.deleteDownloadedModel()
            refreshKokoroModelState()
        } catch {
            modelDeleteError = error.localizedDescription
            refreshKokoroModelState()
        }
    }

    private static func loadEnglishVoices() -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        return all
            .filter { $0.language == TTSPreferenceKeys.voiceLanguage }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

enum TTSVoicePreference {
    static func currentProvider() -> TTSProvider {
        let raw = UserDefaults.standard.string(forKey: TTSPreferenceKeys.provider) ?? TTSProvider.apple.rawValue
        return TTSProvider(rawValue: raw) ?? .apple
    }

    static func resolvedKokoroVoice() -> String {
        let saved = UserDefaults.standard.string(forKey: TTSPreferenceKeys.kokoroVoice) ?? ""
        if !saved.isEmpty, KokoroVoiceCatalog.voice(named: saved) != nil { return saved }
        return KokoroVoiceCatalog.defaultVoice
    }

    static func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let savedIdentifier = UserDefaults.standard.string(forKey: TTSPreferenceKeys.voiceIdentifier) ?? ""
        if !savedIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: savedIdentifier) {
            return voice
        }
        return bestVoice()
    }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let preferredLanguages = [language, "en-US", "en-GB", "en-AU"]

        for lang in preferredLanguages {
            let candidates = voices.filter { $0.language == lang }
            if candidates.isEmpty { continue }
            if let premium = candidates.first(where: { $0.quality == .premium }) {
                return premium
            }
            if let enhanced = candidates.first(where: { $0.quality == .enhanced }) {
                return enhanced
            }
        }

        for lang in preferredLanguages {
            if let voice = AVSpeechSynthesisVoice(language: lang) {
                return voice
            }
        }
        return nil
    }
}
