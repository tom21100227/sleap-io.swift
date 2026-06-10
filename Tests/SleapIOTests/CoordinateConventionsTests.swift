import XCTest
import simd
@testable import SleapIO

/// E4.1: Coordinate-convention helpers.
final class CoordinateConventionsTests: XCTestCase {

    func testPixelCenterCorrectionValue() {
        XCTAssertEqual(CoordinateConventions.pixelCenterCorrection, 0.5)
    }

    func testFlipYScalar() {
        XCTAssertEqual(CoordinateConventions.flipY(10, imageHeight: 100), 90)
        XCTAssertEqual(CoordinateConventions.flipY(0, imageHeight: 100), 100)
    }

    func testFlipYIsItsOwnInverse() {
        let h: Float = 480
        for y: Float in [0, 1.5, 239, 479, 480] {
            let back = CoordinateConventions.flipY(CoordinateConventions.flipY(y, imageHeight: h), imageHeight: h)
            XCTAssertEqual(back, y, accuracy: 1e-4)
        }
    }

    func testFlipYPoint() {
        let p = CoordinateConventions.flipY(SIMD2<Float>(7, 30), imageHeight: 100)
        XCTAssertEqual(p.x, 7)   // x unchanged
        XCTAssertEqual(p.y, 70)  // y flipped
    }
}
