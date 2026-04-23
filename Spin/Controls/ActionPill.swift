import SwiftUI

struct ActionPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.84, green: 0.80, blue: 1.0).opacity(0.80))
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(ActionPillStyle())
    }
}

private struct ActionPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                Capsule()
                    .stroke(Color(red: 0.65, green: 0.55, blue: 0.98).opacity(0.30), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
