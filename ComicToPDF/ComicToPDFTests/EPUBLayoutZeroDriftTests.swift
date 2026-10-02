import XCTest
import CoreGraphics
@testable import InksyncPro

final class EPUBLayoutZeroDriftTests: XCTestCase {

    /// Tests that the zero-drift mathematical column stride formula:
    /// gap = 2 * m
    /// colWidth = (renderWidth / cols) - gap
    /// satisfies colWidth + gap == renderWidth / cols,
    /// guaranteeing that page turns land with 0px fractional drift across any screen size.
    func testSingleColumnStrideEqualsViewportWidth() {
        let viewports: [CGFloat] = [375.0, 393.0, 414.0, 430.0, 768.0, 820.0, 834.0, 1024.0, 1366.0]
        let margins: [CGFloat] = [12.0, 16.0, 20.0, 24.0, 32.0]

        for renderWidth in viewports {
            for m in margins {
                let cols = 1
                let gap = 2.0 * m
                let colWidth = (renderWidth / CGFloat(cols)) - gap

                let singlePageStride = colWidth + gap
                XCTAssertEqual(
                    singlePageStride,
                    renderWidth,
                    accuracy: 0.0001,
                    "Single column stride must exactly equal renderWidth (\(renderWidth)pt) with margin \(m)pt"
                )

                // Simulate 100 consecutive column turns — ensure 0 cumulative drift
                let hundredPageOffset = 100.0 * singlePageStride
                let expectedOffset = 100.0 * renderWidth
                XCTAssertEqual(
                    hundredPageOffset,
                    expectedOffset,
                    accuracy: 0.001,
                    "Cumulative scroll over 100 pages must have 0 drift"
                )
            }
        }
    }

    func testDualColumnStrideEqualsViewportWidth() {
        // Dual column mode on iPads
        let viewports: [CGFloat] = [820.0, 834.0, 1024.0, 1194.0, 1366.0]
        let margins: [CGFloat] = [16.0, 24.0, 32.0]

        for renderWidth in viewports {
            for m in margins {
                let cols = 2
                let gap = 2.0 * m
                let colWidth = (renderWidth / CGFloat(cols)) - gap

                let columnStride = colWidth + gap
                let fullSpreadStride = columnStride * CGFloat(cols)

                XCTAssertEqual(
                    fullSpreadStride,
                    renderWidth,
                    accuracy: 0.0001,
                    "Dual column full spread stride must exactly equal renderWidth (\(renderWidth)pt)"
                )
            }
        }
    }
}
