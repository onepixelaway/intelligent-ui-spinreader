import SwiftUI

@MainActor
final class ScrollState: ObservableObject {
    @Published var currentPage: Int = 0

    private(set) var contentHeight: Double = 0
    private(set) var viewportHeight: Double = 0
    private(set) var pageOffsets: [Double] = [0]
    private(set) var pageVisibleHeights: [Double] = [0]
    private var itemBounds: [(minY: Double, maxY: Double)] = []

    var totalPages: Int { pageOffsets.count }

    var offset: Double {
        guard currentPage < pageOffsets.count else { return -(pageOffsets.last ?? 0) }
        return -pageOffsets[currentPage]
    }

    var isAtBottom: Bool {
        currentPage >= totalPages - 1
    }

    var isAtTop: Bool {
        currentPage <= 0
    }

    var visibleHeight: Double {
        guard currentPage < pageVisibleHeights.count else { return viewportHeight }
        return pageVisibleHeights[currentPage]
    }

    func setScrollBounds(contentHeight: Double, viewportHeight: Double) {
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        recomputePages()
    }

    func setItemBounds(_ bounds: [(minY: Double, maxY: Double)]) {
        self.itemBounds = bounds
        recomputePages()
    }

    private func recomputePages() {
        guard viewportHeight > 0, !itemBounds.isEmpty else {
            updatePageOffsets([0])
            return
        }

        let sorted = itemBounds.sorted { $0.minY < $1.minY }
        guard let contentEnd = sorted.map(\.maxY).max() else {
            updatePageOffsets([0])
            return
        }

        var offsets: [Double] = [0]
        var pageStart: Double = 0

        while pageStart + viewportHeight < contentEnd {
            let pageEnd = pageStart + viewportHeight

            var lastFittingIdx: Int? = nil
            for (i, item) in sorted.enumerated() {
                if item.minY >= pageEnd { break }
                if item.maxY <= pageEnd {
                    lastFittingIdx = i
                }
            }

            if let idx = lastFittingIdx {
                let nextIdx = idx + 1
                if nextIdx < sorted.count {
                    let nextStart = sorted[nextIdx].minY
                    if nextStart > pageStart {
                        offsets.append(nextStart)
                        pageStart = nextStart
                        continue
                    }
                }
            }

            // Item taller than viewport — advance by viewport height
            offsets.append(pageStart + viewportHeight)
            pageStart += viewportHeight
        }

        updatePageOffsets(offsets)
    }

    private func updatePageOffsets(_ offsets: [Double]) {
        guard offsets != pageOffsets else { return }
        pageOffsets = offsets
        if currentPage >= totalPages {
            currentPage = max(0, totalPages - 1)
        }
    }

    func goToNextPage() {
        guard currentPage < totalPages - 1 else { return }
        currentPage += 1
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
    }

    func resetToTop() {
        currentPage = 0
    }
}
