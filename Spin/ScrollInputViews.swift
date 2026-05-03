import SwiftUI
import QuartzCore

struct TrackpadScrollView: View {
    let onSwipeDown: () -> Void
    let onSwipeUp: () -> Void

    @State private var haptics = HapticFeedback()
    @State private var gestureConsumed = false
    @State private var lastPageTurnTime: CFTimeInterval = 0
    @State private var resetGeneration = 0

    private let swipeThreshold: CGFloat = 50.0
    private let cooldownSeconds: CFTimeInterval = 0.35

    var body: some View {
        TrackpadSurface()
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                            scheduleGestureReset()
                            if dy < 0 {
                                onSwipeUp()
                            } else {
                                onSwipeDown()
                            }
                            haptics.perform(speed: 3.0, minInterval: 0)
                        }
                    }
                    .onEnded { _ in
                        resetGeneration += 1
                        gestureConsumed = false
                    }
            )
    }

    private func scheduleGestureReset() {
        resetGeneration += 1
        let generation = resetGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldownSeconds) {
            guard resetGeneration == generation else { return }
            gestureConsumed = false
        }
    }
}
