import SwiftUI

struct ReaderTagPill: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Capsule())
        }
        .buttonStyle(ReaderTagPillStyle())
    }
}

private struct ReaderTagPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(configuration.isPressed ? Color(white: 0.09) : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(Color(white: 0.45), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
