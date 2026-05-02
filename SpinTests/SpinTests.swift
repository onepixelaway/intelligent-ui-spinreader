//
//  SpinTests.swift
//  SpinTests
//
//  Created by Tareq Ismail on 2025-01-10.
//

import Testing
import CoreGraphics
@testable import Spin

struct SpinTests {

    @MainActor
    @Test func visiblePageHeightStopsAtNextPageBoundary() {
        let state = ScrollState()

        state.setPageStarts([0, 96, 220])

        #expect(state.visiblePageHeight(for: 120) == 96)
        state.goToNextPage()
        #expect(state.visiblePageHeight(for: 120) == 120)
    }

    @MainActor
    @Test func transientOffsetsStopAtNextPageBoundary() {
        let state = ScrollState()

        state.setPageStarts([0, 96, 220])
        state.goToContentOffset(24)

        #expect(state.visiblePageHeight(for: 120) == 72)
    }

    @MainActor
    @Test func playbackTargetAdvancesWhenHighlightStartsOnNextPage() {
        let state = ScrollState()
        state.setPageStarts([0, 96, 220])

        let target = state.forwardPlaybackTargetPage(
            for: CGRect(x: 0, y: 100, width: 200, height: 18),
            viewportHeight: 120,
            isWordHighlight: true
        )

        #expect(target == 1)
    }

    @MainActor
    @Test func playbackTargetAdvancesWhenSentenceCrossesPageBoundary() {
        let state = ScrollState()
        state.setPageStarts([0, 96, 220])

        let target = state.forwardPlaybackTargetPage(
            for: CGRect(x: 0, y: 80, width: 200, height: 40),
            viewportHeight: 120,
            isWordHighlight: false
        )

        #expect(target == 1)
    }

    @MainActor
    @Test func playbackTargetDoesNotAdvanceForVisibleHighlight() {
        let state = ScrollState()
        state.setPageStarts([0, 96, 220])

        let target = state.forwardPlaybackTargetPage(
            for: CGRect(x: 0, y: 40, width: 200, height: 18),
            viewportHeight: 120,
            isWordHighlight: true
        )

        #expect(target == nil)
    }

    @MainActor
    @Test func playbackTargetUsesWordPageEvenBeforeVisibleBottomCheckWouldMove() {
        let state = ScrollState()
        state.setPageStarts([0, 96, 220])

        let target = state.forwardPlaybackTargetPage(
            for: CGRect(x: 0, y: 96, width: 30, height: 18),
            viewportHeight: 96,
            isWordHighlight: true
        )

        #expect(target == 1)
    }

    @MainActor
    @Test func highlightPageChangeWaitsUntilHighlightStartsOnNextPage() {
        let state = ScrollState()
        state.setPageStarts([0, 96, 220])

        #expect(state.pageChangeForContentStart(at: 80, movingForward: true) == nil)
        #expect(state.pageChangeForContentStart(at: 96, movingForward: true) == 1)
    }

    @MainActor
    @Test func highlightPageChangeDoesNotUseTransientOffsets() {
        let state = ScrollState()
        state.setPageStarts([0, 96, 220])
        state.goToPage(1)

        #expect(state.pageChangeForContentStart(at: 140, movingForward: false) == nil)
        #expect(state.pageChangeForContentStart(at: 80, movingForward: false) == 0)
    }

}
