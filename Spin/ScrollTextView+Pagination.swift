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
                      let attributed = paginationAttributedText(for: item, at: idx) else { return nil }
                let measuredLines = Paginator.measureLines(
                    for: attributed,
                    width: paginationTextWidth(for: item, viewportWidth: viewportWidth)
                )
                let yOffset = paginationLineYOffset(for: item)
                guard yOffset != 0 else { return measuredLines }
                return measuredLines.map { line in
                    Paginator.LineFragment(
                        minY: line.minY + yOffset,
                        maxY: line.maxY + yOffset
                    )
                }
            },
            forcesPageBreak: { idx in
                guard itemsSnapshot.indices.contains(idx) else { return false }
                if case .divider = itemsSnapshot[idx] { return true }
                return false
            }
        ))
        scrollState.setPageStarts(starts)
    }

    // SHARED WITH HIGHLIGHT NAVIGATION: paginationAlignedLineMinY in ScrollTextView+Highlights
    // calls this to produce line y-offsets that match pageStarts exactly. If you change the
    // width calculation here, the same change must hold for the highlight paging path too,
    // otherwise sentences at a page boundary will fail to trigger a page flip.
    func paginationTextWidth(for item: ReadableItem, viewportWidth: Double) -> Double {
        let itemWidth = viewportWidth - 2 * Double(horizontalPadding(for: item))
        switch item {
        case .blockquote:
            return itemWidth - 15
        case .callout:
            return itemWidth - 15 - 24
        case .listItem:
            return itemWidth - Double(extraLeading(for: item))
        case .title, .byline, .paragraph, .richParagraph, .subheading, .paragraphWithFootnotes:
            return itemWidth
        case .image, .code, .divider, .chapterTOC:
            return itemWidth
        }
    }

    private func paginationLineYOffset(for item: ReadableItem) -> Double {
        switch item {
        case .callout:
            return 14
        case .title, .byline, .paragraph, .richParagraph, .subheading, .listItem, .blockquote, .paragraphWithFootnotes, .image, .code, .divider, .chapterTOC:
            return 0
        }
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
