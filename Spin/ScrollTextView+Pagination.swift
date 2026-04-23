import SwiftUI
import UIKit

extension ScrollTextView {
    // Reported frames are in the ScrollView's "scroll" space and shift with the VStack's
    // `.offset(y:)` for paging. Convert back to content space first, then skip the Paginator
    // entirely if those frames haven't actually changed since last run (the hot path during
    // a page-flip animation fires this closure repeatedly with only the offset changing).
    func recomputePageStarts(
        positions: [Int: CGRect],
        viewportHeight: Double,
        viewportWidth: Double
    ) {
        let offset = CGFloat(scrollState.offset)
        var contentFrames: [Int: CGRect] = [:]
        contentFrames.reserveCapacity(positions.count)
        for (idx, frame) in positions {
            contentFrames[idx] = CGRect(
                x: frame.minX,
                y: frame.minY - offset,
                width: frame.width,
                height: frame.height
            )
        }
        if contentFrames == lastPaginationFrames
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
