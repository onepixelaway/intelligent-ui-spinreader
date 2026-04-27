import Foundation
import UIKit

// Computes line-aware page breaks across a VStack of ReadableItems.
//
// The view already lays out items and reports per-item scroll-space rects via `paragraphFrames`.
// This paginator decides where *within* long text items a page should break so no paragraph is
// cut mid-line and so pages respect paragraph boundaries with widow/orphan control.
@MainActor
enum Paginator {
    // Orphan: refuse to start a paragraph on a page that can only hold this many lines of it.
    // The paragraph is pushed whole to the next page instead.
    static let minLinesAtPageEnd: Int = 2

    // Widow: refuse to leave this few trailing lines of a paragraph alone at the top of the next
    // page. Pull a line back so the next page starts with at least minLinesAtPageStart+1 lines.
    static let minLinesAtPageStart: Int = 2

    // y-coordinates are in the item's own coordinate space — y = 0 is the first line's top.
    struct LineFragment {
        let minY: Double
        let maxY: Double
    }

    struct Input {
        // Frames in scroll-content coordinates (from ParagraphPositionKey).
        let itemFrames: [Int: CGRect]
        let itemCount: Int
        let viewportHeight: Double
        // Returns line fragments for splittable items; nil for atomic items, which cannot
        // be broken and move whole to the next page.
        let splittableLines: (_ itemIndex: Int) -> [LineFragment]?
        let forcesPageBreak: (_ itemIndex: Int) -> Bool
    }

    // Output y-coordinates in scroll-content space. pageStarts[0] is always 0.
    static func computePageStarts(input: Input) -> [Double] {
        guard input.itemCount > 0, input.viewportHeight > 0 else { return [0] }

        // Items are laid out in order; sorting by minY tolerates dict iteration.
        let ordered: [(index: Int, frame: CGRect)] = (0..<input.itemCount)
            .compactMap { idx -> (Int, CGRect)? in
                guard let f = input.itemFrames[idx], f.height > 0 else { return nil }
                return (idx, f)
            }
            .sorted { $0.1.minY < $1.1.minY }

        guard !ordered.isEmpty else { return [0] }

        var pageStarts: [Double] = [0]
        var currentPageStart: Double = 0

        func commitBreak(at y: Double) {
            guard y > currentPageStart + 1 else { return }
            pageStarts.append(y)
            currentPageStart = y
        }

        for (idx, frame) in ordered {
            let itemMinY = Double(frame.minY)
            let itemMaxY = Double(frame.maxY)

            // Hard page break (e.g., chapter dividers).
            if input.forcesPageBreak(idx), itemMinY > currentPageStart {
                commitBreak(at: itemMinY)
            }

            if let lines = input.splittableLines(idx), !lines.isEmpty {
                var lineCursor = 0
                while lineCursor < lines.count {
                    let line = lines[lineCursor]
                    let absMaxY = itemMinY + line.maxY
                    if absMaxY - currentPageStart > input.viewportHeight {
                        var breakLineIndex = lineCursor
                        let firstOnPage = firstLineOfItemOnPage(
                            lines: lines,
                            itemMinY: itemMinY,
                            pageStart: currentPageStart
                        )
                        let linesPlacedFromThisItem = lineCursor - firstOnPage

                        // Orphan: too few lines of this paragraph made it onto the current
                        // page — push the whole paragraph to the next page.
                        if linesPlacedFromThisItem > 0, linesPlacedFromThisItem < Paginator.minLinesAtPageEnd {
                            breakLineIndex = firstOnPage
                        }

                        // Widow: too few trailing lines would land alone on the next page.
                        // Pull one more line onto the current page by breaking earlier.
                        let remainingAfter = lines.count - breakLineIndex
                        if remainingAfter > 0, remainingAfter < Paginator.minLinesAtPageStart, breakLineIndex > 0 {
                            let candidate = breakLineIndex - 1
                            if candidate > firstOnPage {
                                breakLineIndex = candidate
                            }
                        }

                        // The break line must start strictly after viewport end, otherwise the
                        // line straddles the page edge and would render on both pages. Exception:
                        // if it starts exactly at viewport end and the prior line fully fits,
                        // the boundary is clean.
                        let viewportEnd = currentPageStart + input.viewportHeight
                        while breakLineIndex < lines.count {
                            let lineTop = itemMinY + lines[breakLineIndex].minY
                            if lineTop > viewportEnd { break }
                            if lineTop == viewportEnd,
                               breakLineIndex == 0 || itemMinY + lines[breakLineIndex - 1].maxY <= viewportEnd {
                                break
                            }
                            breakLineIndex += 1
                        }

                        let breakY = itemMinY + lines[breakLineIndex].minY
                        if breakY > currentPageStart {
                            commitBreak(at: breakY)
                            lineCursor = breakLineIndex
                            continue
                        }
                        // Break didn't advance (line is at/before current page start, e.g. a
                        // paragraph taller than the viewport starting at page top). Advance by
                        // a full viewport to guarantee forward progress.
                        commitBreak(at: currentPageStart + input.viewportHeight)
                        lineCursor = breakLineIndex
                        continue
                    }
                    lineCursor += 1
                }
            } else if (itemMaxY - currentPageStart) > input.viewportHeight, itemMinY > currentPageStart {
                // Atomic item doesn't fit; push it to a new page.
                commitBreak(at: itemMinY)
            }
        }

        return pageStarts
    }

    // First line index of `item` whose bottom sits after `pageStart` — i.e. the first line
    // that "starts" on the current page. Used for widow/orphan counting.
    private static func firstLineOfItemOnPage(
        lines: [LineFragment],
        itemMinY: Double,
        pageStart: Double
    ) -> Int {
        for (i, l) in lines.enumerated() {
            if itemMinY + l.maxY >= pageStart {
                return i
            }
        }
        return lines.count
    }

    // TextKit line-fragment measurement. Matches HighlightableTextView's configuration
    // (lineFragmentPadding = 0) so measured line rects align with what gets rendered.
    static func measureLines(for attributed: NSAttributedString, width: Double) -> [LineFragment] {
        guard width > 0, attributed.length > 0 else { return [] }

        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        _ = layoutManager.glyphRange(for: container)

        var fragments: [LineFragment] = []
        let fullGlyphRange = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: fullGlyphRange) { rect, _, _, _, _ in
            fragments.append(LineFragment(minY: Double(rect.minY), maxY: Double(rect.maxY)))
        }
        return fragments
    }
}
