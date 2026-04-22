import SwiftUI

@MainActor
final class ScrollState: ObservableObject {
    @Published var offset: Double = 0
    private let paginatedSnapSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)

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

    func handleScroll(direction: Double, paginatedChunk: CGFloat) {
        let step = direction * Double(paginatedChunk)
        let target = offset + step
        let snapped = clamp((target / Double(paginatedChunk)).rounded() * Double(paginatedChunk))
        guard snapped != offset else { return }
        withAnimation(paginatedSnapSpring) {
            offset = snapped
        }
    }

    func snapToBoundsIfNeeded() {
        let clamped = clamp(offset)
        guard clamped != offset else { return }
        withAnimation(paginatedSnapSpring) {
            offset = clamped
        }
    }
}
