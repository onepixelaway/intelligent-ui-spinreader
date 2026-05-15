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

// MARK: - Shared Row

@MainActor @ViewBuilder
func settingsSelectableRow<Content: View>(
    isSelected: Bool,
    action: @escaping () -> Void,
    isDisabled: Bool = false,
    @ViewBuilder content: () -> Content
) -> some View {
    Button(action: action) {
        HStack {
            content()
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
}

// MARK: - Settings Hub

struct SettingsView: View {
    @ObservedObject var articleStore: WebArticleStore

    var body: some View {
        List {
            Section {
                settingsCategory(
                    icon: "textformat.size",
                    iconColor: .indigo,
                    title: "Appearance",
                    destination: ReaderAppearanceSettingsView()
                )
                settingsCategory(
                    icon: "waveform",
                    iconColor: .blue,
                    title: "Audio Narration",
                    destination: AudioNarrationSettingsView()
                )
                settingsCategory(
                    icon: "highlighter",
                    iconColor: .yellow,
                    title: "Highlighting",
                    destination: HighlightingSettingsView()
                )
                settingsCategory(
                    icon: "hand.draw",
                    iconColor: .teal,
                    title: "Gestures",
                    destination: GesturesSettingsView()
                )
                settingsCategory(
                    icon: "sparkles",
                    iconColor: .purple,
                    title: "AI Actions",
                    destination: PanelActionsSettingsView()
                )
                settingsCategory(
                    icon: "bookmark",
                    iconColor: .black,
                    title: "X Bookmarks",
                    destination: XBookmarksSettingsView(articleStore: articleStore)
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

// MARK: - X Bookmarks Settings

struct XBookmarksSettingsView: View {
    @ObservedObject var articleStore: WebArticleStore
    @StateObject private var syncManager = XBookmarksSyncManager()
    @State private var showDisconnectConfirmation = false

    var body: some View {
        List {
            accountSection
            syncSection
            developerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.automatic)
        .navigationTitle("X Bookmarks")
        .navigationBarTitleDisplayMode(.automatic)
        .confirmationDialog(
            "Disconnect X?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                syncManager.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your saved articles stay in Ponder. Only the X connection is removed.")
        }
        .alert("X Bookmarks", isPresented: Binding(
            get: { syncManager.errorMessage != nil },
            set: { if !$0 { syncManager.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(syncManager.errorMessage ?? "")
        }
    }

    private var accountSection: some View {
        Section {
            if syncManager.isConnected {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(syncManager.displayName.isEmpty ? "Connected" : syncManager.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                        if !syncManager.username.isEmpty {
                            Text("@\(syncManager.username)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Button(role: .destructive) {
                    showDisconnectConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Disconnect X")
                    }
                }
                .disabled(syncManager.isWorking)
            } else {
                Button {
                    Task { await syncManager.connect() }
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.plus")
                        Text(syncManager.isWorking ? "Connecting..." : "Connect X")
                        Spacer()
                        if syncManager.isWorking {
                            ProgressView()
                        }
                    }
                }
                .disabled(syncManager.isWorking || XBookmarksConfig.oauthClientID.isEmpty)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Spin asks X for read-only bookmark access and stores the sign-in token in the device keychain.")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task { await syncManager.syncBookmarks(into: articleStore) }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(syncManager.isWorking ? "Syncing..." : "Sync Bookmarks")
                    Spacer()
                    if syncManager.isWorking {
                        ProgressView()
                    }
                }
            }
            .disabled(!syncManager.isConnected || syncManager.isWorking)

            if !syncManager.progressText.isEmpty {
                Text(syncManager.progressText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !syncManager.lastSummary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Sync")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(syncManager.lastSummary.statusLine)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Linked bookmarks are saved as readable articles. Bookmarks without a link are saved as readable post snapshots.")
        }
    }

    private var developerSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OAuth callback URL")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(XBookmarksConfig.redirectURI)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = XBookmarksConfig.redirectURI
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy callback URL")
            }
        } header: {
            Text("X Developer App")
        } footer: {
            Text("Register this URL under your X app’s OAuth 2.0 settings. The Client ID is embedded in the app (Info.plist key XOAuthClientID).")
        }
    }
}

// MARK: - Audio Narration Settings

struct AudioNarrationSettingsView: View {
    @AppStorage(TTSPreferenceKeys.provider) private var providerRaw: String = TTSProvider.kokoro.rawValue
    @AppStorage(TTSPreferenceKeys.voiceIdentifier) private var voiceIdentifier: String = ""
    @AppStorage(TTSPreferenceKeys.kokoroVoice) private var kokoroVoice: String = KokoroVoiceCatalog.defaultVoice
    @State private var isKokoroModelDownloaded = KokoroPaths.isModelDownloaded
    @State private var showDeleteModelConfirmation = false
    @State private var modelDeleteError: String?

    private let voices: [AVSpeechSynthesisVoice] = AudioNarrationSettingsView.loadEnglishVoices()

    private var selectedProvider: TTSProvider {
        TTSProvider(rawValue: providerRaw) ?? .kokoro
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
        let raw = UserDefaults.standard.string(forKey: TTSPreferenceKeys.provider) ?? TTSProvider.kokoro.rawValue
        return TTSProvider(rawValue: raw) ?? .kokoro
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
