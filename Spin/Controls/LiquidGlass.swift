import SwiftUI

extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(
        in shape: S,
        tint: Color = Color(white: 0.08).opacity(0.10),
        featherRadius: CGFloat = 3
    ) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
                .mask(shape.blur(radius: featherRadius))
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }
}
