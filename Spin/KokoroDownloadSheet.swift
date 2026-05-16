import SwiftUI

struct KokoroDownloadSheet: View {
    @ObservedObject var coordinator: ReaderSpeechCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.white.opacity(0.85))

                contentForState

                Spacer()

                actionButtons
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var contentForState: some View {
        switch coordinator.kokoroPreparation {
        case .awaitingDownloadConsent:
            VStack(spacing: 12) {
                Text("Kokoro TTS")
                    .font(.custom("DMSans-Black", size: 22))
                    .foregroundColor(.white)
                Text("This neural voice requires a one-time download of the Kokoro model (~312 MB). Use Wi-Fi for the best experience.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                Text("Privacy first — runs entirely on device, nothing sent to the cloud.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                Button {
                    UserDefaults.standard.set(TTSProvider.apple.rawValue, forKey: TTSPreferenceKeys.provider)
                    coordinator.cancelKokoroPreparation()
                } label: {
                    Text("Use Apple Voice Instead")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }

        case .downloading(let received, let total):
            VStack(spacing: 16) {
                Text("Downloading model")
                    .font(.custom("DMSans-Black", size: 18))
                    .foregroundColor(.white)

                ProgressView(value: progressValue(received: received, total: total))
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: .infinity)

                HStack {
                    Text("\(KokoroByteFormatter.megabytes(received)) / \(KokoroByteFormatter.megabytes(total))")
                    Spacer()
                    Text("\(percentString(received: received, total: total))")
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
            }

        case .loadingModel:
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Loading neural model…")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7))
            }

        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange.opacity(0.85))
                Text("Download failed")
                    .font(.custom("DMSans-Black", size: 18))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch coordinator.kokoroPreparation {
        case .awaitingDownloadConsent:
            HStack(spacing: 12) {
                pillButton("Not now", isPrimary: false) {
                    coordinator.cancelKokoroPreparation()
                }
                pillButton(
                    "Download \(KokoroByteFormatter.megabytes(KokoroPaths.modelExpectedBytes))",
                    isPrimary: true
                ) {
                    coordinator.confirmKokoroDownload()
                }
            }

        case .downloading:
            pillButton("Cancel", isPrimary: false) {
                coordinator.cancelKokoroPreparation()
            }

        case .loadingModel:
            EmptyView()

        case .error:
            pillButton("Dismiss", isPrimary: true) {
                coordinator.dismissKokoroError()
            }

        case .idle:
            EmptyView()
        }
    }

    private func pillButton(
        _ label: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: isPrimary ? .semibold : .medium))
                .foregroundColor(isPrimary ? .black : .white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isPrimary ? Color.white : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func progressValue(received: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(received) / Double(total)))
    }

    private func percentString(received: Int64, total: Int64) -> String {
        let pct = Int(progressValue(received: received, total: total) * 100)
        return "\(pct)%"
    }
}
