import SwiftUI

struct CircularReaderButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var showsAudioActivity: Bool = false
    var audioActivityLevel: Double = 0
    let action: () -> Void

    private let borderColor = Color.white.opacity(0.08)

    var body: some View {
        Button(action: action) {
            ZStack {
                if showsAudioActivity {
                    AudioActivityBars(level: audioActivityLevel)
                }

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color(white: 0.83))
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 20))
                        .foregroundColor(Color(white: 0.83))
                }
            }
            .frame(width: 56, height: 56)
            .liquidGlass(in: Circle(), tint: Color.black.opacity(0.6))
            .overlay(
                Circle()
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(Circle())
        }
        .buttonStyle(CircularReaderButtonStyle())
        .disabled(isDisabled || isLoading)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AudioActivityBars: View {
    let level: Double
    private let multipliers: [Double] = [0.28, 0.55, 0.95, 0.7, 1.0, 0.62, 0.32]

    var body: some View {
        let normalized = min(max(level, 0), 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(multipliers.enumerated()), id: \.offset) { _, multiplier in
                let height = 5 + normalized * multiplier * 31
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 3, height: height)
            }
        }
        .frame(width: 48, height: 42, alignment: .bottom)
        .offset(y: 7)
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.055), value: level)
    }
}

private struct CircularReaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
