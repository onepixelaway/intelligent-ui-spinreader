//
//  SpinTests.swift
//  SpinTests
//
//  Created by Tareq Ismail on 2025-01-10.
//

import Testing
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

}
