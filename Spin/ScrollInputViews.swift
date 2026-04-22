import SwiftUI
import QuartzCore

struct ScrollWheel: View {
    let onScrolled: (Double) -> Void

    @State private var startAngle: Double?
    @State private var rotation: Double = 0
    @State private var lastDelta: Double = 0
    @State private var lastDirection: Double = 0

    @State private var haptics = HapticFeedback()

    private let stepDegrees = 30.0
    private let hapticInterval: CFTimeInterval = 0.1

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Circle()
                    .fill(.gray.opacity(0.06))

                Circle()
                    .stroke(.gray.opacity(0.22), lineWidth: diameter * (22.0 / 132.0))
                    .padding(diameter * (13.0 / 264.0))

                Circle()
                    .stroke(.white.opacity(0.17), lineWidth: 2)
                    .padding(diameter * (33.0 / 264.0))

                Circle()
                    .fill(.white)
                    .frame(width: diameter * (22.0 / 132.0), height: diameter * (22.0 / 132.0))
                    .offset(y: -diameter * (60.0 / 132.0))
                    .rotationEffect(.degrees(rotation))
            }
            .contentShape(Circle())
            .onAppear { haptics.prepare() }
            .gesture(dragGesture(center: center))
        }
    }

    private func dragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let currentAngle = angle(from: center, to: gesture.location)

                guard let start = startAngle else {
                    startAngle = currentAngle
                    lastDelta = 0
                    lastDirection = 0
                    return
                }

                var delta = currentAngle - start
                if delta > 180 { delta -= 360 }
                else if delta < -180 { delta += 360 }

                let movement = delta - lastDelta
                lastDelta = delta

                if abs(movement) > 0.5 {
                    lastDirection = movement > 0 ? -1.0 : 1.0
                }

                let previousRotation = rotation
                rotation += movement

                let currentStep = floor(abs(rotation) / stepDegrees)
                let previousStep = floor(abs(previousRotation) / stepDegrees)

                if currentStep != previousStep, lastDirection != 0 {
                    onScrolled(lastDirection)
                    haptics.perform(speed: abs(movement) / 0.016, minInterval: hapticInterval)
                }
            }
            .onEnded { _ in
                startAngle = nil
                lastDelta = 0
                lastDirection = 0
            }
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let degrees = atan2(dy, dx) * (180.0 / .pi)
        return (degrees + 90.0).truncatingRemainder(dividingBy: 360.0)
    }
}

struct TrackpadScrollView: View {
    let onDrag: (Double) -> Void   // positive delta = swipe down (scroll content up)
    let onFlick: (Double) -> Void  // ±1 direction on fast release

    @State private var haptics = HapticFeedback()
    @State private var hapticAccumulator: CGFloat = 0
    @State private var lastTranslation: CGFloat = 0

    private let hapticInterval: CFTimeInterval = 0.08
    private let hapticStepPoints: CGFloat = 40.0
    private let flickThreshold: CGFloat = 35.0

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
            }
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
                        }
                    }
            )
        }
    }
}
