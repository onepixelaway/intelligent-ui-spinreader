import SwiftUI
import UIKit

extension ScrollTextView {
    // Frames arrive normalized into scroll-content space, so pagination and highlighting both use
    // the same coordinate system: page 0 starts at y=0, page 1 starts at `pageStarts[1]`, and so on.
    func recomputePageStarts(
        positions: [Int: CGRect],
        viewportHeight: Double,
        viewportWidth: Double
    ) {
        let contentFrames = positions
        if paginationFramesMatchLast(contentFrames)
            && viewportHeight == lastPaginationViewportHeight
            && viewportWidth == lastPaginationViewportWidth {
            return
        }
        lastPaginationFrames = contentFrames
        lastPaginationViewportHeight = viewportHeight
        lastPaginationViewportWidth = viewportWidth

        let itemsSnapshot = items
        let starts = Paginator.computePageStarts(input: Paginator.Input(
            itemFrames: contentFrames,
            itemCount: itemsSnapshot.count,
            viewportHeight: viewportHeight,
            splittableLines: { idx in
                guard itemsSnapshot.indices.contains(idx) else { return nil }
                let item = itemsSnapshot[idx]
                guard item.isSplittable,
                      let attributed = renderedAttributedText(for: item) else { return nil }
                let textWidth = viewportWidth - 2 * Double(horizontalPadding(for: item))
                return Paginator.measureLines(for: attributed, width: textWidth)
            },
            forcesPageBreak: { idx in
                guard itemsSnapshot.indices.contains(idx) else { return false }
                if case .divider = itemsSnapshot[idx] { return true }
                return false
            }
        ))
        scrollState.setPageStarts(starts)
    }

    private func paginationFramesMatchLast(_ frames: [Int: CGRect]) -> Bool {
        if frames == lastPaginationFrames {
            return true
        }
        guard frames.count == lastPaginationFrames.count, !frames.isEmpty else {
            return false
        }

        for (idx, frame) in frames {
            guard let previous = lastPaginationFrames[idx] else { return false }
            guard framesApproximatelyEqual(frame, previous) else {
                return false
            }
        }
        return true
    }

    private func framesApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5
            && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5
            && abs(lhs.height - rhs.height) <= 0.5
    }

    // Typography and viewport-size changes don't always move item frames in the same pass —
    // SwiftUI may re-lay out async and ParagraphPositionKey fires later. This safety net
    // recomputes against current frames so a change isn't silently missed.
    func recomputePageStartsWithCurrentFrames(
        viewportHeight: Double,
        viewportWidth: Double
    ) {
        recomputePageStarts(
            positions: paragraphFrames,
            viewportHeight: viewportHeight,
            viewportWidth: viewportWidth
        )
    }
}
