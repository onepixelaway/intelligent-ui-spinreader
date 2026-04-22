import SwiftUI
import QuartzCore

@MainActor
final class ScrollState: ObservableObject {
    @Published var offset: Double = 0
    private var velocity: Double = 0
    private var lastScrollTime = CACurrentMediaTime()
    private var momentumTask: Task<Void, Never>?

    private let baseScrollSpeed: Double = 7
    private let maxVelocity: Double = 40.0
    private let deceleration: Double = 0.3
    private let acceleration: Double = 4
    private let activeFrameNanos: UInt64 = 8_333_333
    private let idleFrameNanos: UInt64 = 50_000_000
    private let momentumSpring = Animation.interpolatingSpring(stiffness: 170, damping: 25)
    private let paginatedSnapSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)

    init() {
        startMomentumTimer()
    }

    deinit {
        momentumTask?.cancel()
    }

    private var contentHeight: Double = 0
    private var viewportHeight: Double = 0
    private var minOffset: Double { guard contentHeight > viewportHeight else { return 0 }; return -(contentHeight - viewportHeight) - 120 }
    private var maxOffset: Double { 0 }

    var isAtBottom: Bool {
        guard contentHeight > viewportHeight else { return false }
        let contentBottom = -(contentHeight - viewportHeight)
        return offset <= contentBottom + 5
    }

    func setScrollBounds(contentHeight: Double, viewportHeight: Double) {
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
    }

    private func clamp(_ value: Double) -> Double {
        min(maxOffset, max(minOffset, value))
    }

    func applyDirectDelta(_ delta: Double) {
        let proposed = offset + delta
        if proposed > maxOffset || proposed < minOffset {
            offset += delta * 0.25
        } else {
            offset = proposed
        }
    }

    func applyFlick(direction: Double) {
        velocity = direction * maxVelocity
        lastScrollTime = CACurrentMediaTime()
        withAnimation(momentumSpring) {
            offset = clamp(offset + velocity * 3)
        }
    }

    func handleScroll(direction: Double, paginatedChunk: CGFloat? = nil) {
        let now = CACurrentMediaTime()
        let timeDelta = now - lastScrollTime
        lastScrollTime = now

        if let chunk = paginatedChunk, chunk > 0 {
            velocity = 0
            let step = direction * Double(chunk)
            let target = offset + step
            let snapped = (target / Double(chunk)).rounded() * Double(chunk)
            guard snapped != offset else { return }
            withAnimation(paginatedSnapSpring) {
                offset = snapped
            }
            return
        }

        if direction * velocity > 0 && timeDelta < 0.5 {
            velocity = (velocity + direction * baseScrollSpeed) * acceleration
        } else {
            velocity = direction * baseScrollSpeed
        }

        velocity = min(maxVelocity, max(-maxVelocity, velocity))

        withAnimation(momentumSpring) {
            offset = clamp(offset + velocity)
        }
    }

    private func startMomentumTimer() {
        momentumTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isIdle = abs(self.velocity) <= 0.1
                let sleepNanos = isIdle ? self.idleFrameNanos : self.activeFrameNanos
                try? await Task.sleep(nanoseconds: sleepNanos)

                let timeSinceLastScroll = CACurrentMediaTime() - self.lastScrollTime
                if timeSinceLastScroll > 0.1 {
                    let clamped = self.clamp(self.offset)
                    if clamped != self.offset {
                        self.velocity = 0
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            self.offset = clamped
                        }
                    } else if abs(self.velocity) > 0.1 {
                        self.velocity *= self.deceleration
                        withAnimation(self.momentumSpring) {
                            self.offset += self.velocity
                        }
                    }
                }
            }
        }
    }
}
