import SwiftUI
import QuartzCore

struct TrackpadScrollView: View {
    let onDrag: (Double) -> Void   // positive delta = swipe down (scroll content up)
    let onFlick: (Double) -> Void  // ±1 direction on fast release
    var onRelease: (() -> Void)?

    @State private var haptics = HapticFeedback()
    @State private var hapticAccumulator: CGFloat = 0
    @State private var lastTranslation: CGFloat = 0

    private let hapticInterval: CFTimeInterval = 0.08
    private let hapticStepPoints: CGFloat = 40.0
    private let flickThreshold: CGFloat = 35.0

    var body: some View {
        GeometryReader { _ in
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onAppear { haptics.prepare() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let current = value.translation.height
                        let delta = current - lastTranslation
                        lastTranslation = current

                        if delta != 0 {
                            onDrag(Double(delta))

                            hapticAccumulator += abs(delta)
                            if hapticAccumulator >= hapticStepPoints {
                                hapticAccumulator = 0
                                haptics.perform(speed: abs(Double(delta)) * 5, minInterval: hapticInterval)
                            }
                        }
                    }
                    .onEnded { value in
                        lastTranslation = 0
                        hapticAccumulator = 0
                        let extraMomentum = value.predictedEndTranslation.height - value.translation.height
                        if abs(extraMomentum) > flickThreshold {
                            onFlick(extraMomentum > 0 ? 1.0 : -1.0)
                        } else {
                            onRelease?()
                        }
                    }
            )
        }
    }
}
