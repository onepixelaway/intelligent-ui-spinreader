import SwiftUI
import QuartzCore

struct TrackpadScrollView: View {
    let onPageUp: () -> Void
    let onPageDown: () -> Void

    @State private var haptics = HapticFeedback()
    @State private var gestureConsumed = false
    @State private var lastPageTurnTime: CFTimeInterval = 0

    private let swipeThreshold: CGFloat = 50.0
    private let cooldownSeconds: CFTimeInterval = 0.35

    var body: some View {
        GeometryReader { _ in
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onAppear { haptics.prepare() }
                .gesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            guard !gestureConsumed else { return }
                            let dy = value.translation.height
                            if abs(dy) >= swipeThreshold {
                                let now = CACurrentMediaTime()
                                guard now - lastPageTurnTime >= cooldownSeconds else {
                                    gestureConsumed = true
                                    return
                                }
                                gestureConsumed = true
                                lastPageTurnTime = now
                                if dy < 0 {
                                    onPageDown()
                                } else {
                                    onPageUp()
                                }
                                haptics.perform(speed: 3.0, minInterval: 0)
                            }
                        }
                        .onEnded { _ in
                            gestureConsumed = false
                        }
                )
        }
    }
}
