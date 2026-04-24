import SwiftUI

struct CircularReaderButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    private let borderColor = Color.white.opacity(0.08)

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundColor(Color(white: 0.83))
                .frame(width: 56, height: 56)
                .liquidGlass(in: Circle(), tint: Color.black.opacity(0.6))
                .overlay(
                    Circle()
                        .stroke(borderColor, lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(CircularReaderButtonStyle())
        .accessibilityLabel(accessibilityLabel)
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
