import SwiftUI

// Hidden for now; keep the view and model in place to re-enable later.
struct CurrentQuestionView: View {
    let text: String
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.gray.opacity(0.7))
            .opacity(isLoading ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isLoading)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .onTapGesture(perform: onTap)
    }
}
