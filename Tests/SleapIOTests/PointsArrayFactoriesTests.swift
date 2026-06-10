import XCTest
@testable import SleapIO

/// E2.6: PointsArray.from(array:) / from(dict:) factory tests.
///
/// Mirrors the upstream sleap-io `PointsArray.from_array` / `from_dict`
/// helpers: build a points array from an (N, 2) coordinate array or from a
/// node-name -> [x, y] dictionary keyed against a skeleton.
final class PointsArrayFactoriesTests: XCTestCase {

    // MARK: - from(array:)

    func testFromArrayInfersCount() {
        let pa = PointsArray.from(array: [[1, 2], [3, 4], [5, 6]])
        XCTAssertEqual(pa.count, 3)
    }

    func testFromArrayPlacesCoordinatesInOrder() {
        let pa = PointsArray.from(array: [[1, 2], [3, 4]])
        XCTAssertEqual(pa[0].x, 1)
        XCTAssertEqual(pa[0].y, 2)
        XCTAssertEqual(pa[1].x, 3)
        XCTAssertEqual(pa[1].y, 4)
    }

    func testFromArrayMarksFiniteRowsVisible() {
        let pa = PointsArray.from(array: [[1, 2], [3, 4]])
        XCTAssertTrue(pa[0].visible)
        XCTAssertTrue(pa[1].visible)
    }

    func testFromArrayMarksNaNRowsInvisible() {
        let pa = PointsArray.from(array: [[1, 2], [Float.nan, 4], [5, Float.nan]])
        XCTAssertTrue(pa[0].visible, "Finite row should be visible")
        XCTAssertFalse(pa[1].visible, "Row with NaN x should be invisible")
        XCTAssertFalse(pa[2].visible, "Row with NaN y should be invisible")
    }

    func testFromArrayEmptyProducesEmptyArray() {
        let pa = PointsArray.from(array: [])
        XCTAssertEqual(pa.count, 0)
    }

    // MARK: - from(dict:)

    private func makeSkeleton() -> Skeleton {
        Skeleton(
            name: "test",
            nodes: [Node(name: "head"), Node(name: "thorax"), Node(name: "abdomen")]
        )
    }

    func testFromDictCountMatchesSkeleton() {
        let skel = makeSkeleton()
        let pa = PointsArray.from(dict: ["head": [1, 2]], skeleton: skel)
        XCTAssertEqual(pa.count, skel.nodes.count)
        XCTAssertEqual(pa.count, 3)
    }

    func testFromDictSetsSkeleton() {
        let skel = makeSkeleton()
        let pa = PointsArray.from(dict: ["head": [1, 2]], skeleton: skel)
        XCTAssertNotNil(pa.skeleton)
        XCTAssertTrue(pa.skeleton === skel)
    }

    func testFromDictOrdersBySkeletonNodeOrder() {
        let skel = makeSkeleton()
        let pa = PointsArray.from(
            dict: ["abdomen": [5, 6], "head": [1, 2], "thorax": [3, 4]],
            skeleton: skel
        )
        // head is node 0, thorax node 1, abdomen node 2 — dict order is irrelevant.
        XCTAssertEqual(pa[0].x, 1)
        XCTAssertEqual(pa[0].y, 2)
        XCTAssertEqual(pa[1].x, 3)
        XCTAssertEqual(pa[1].y, 4)
        XCTAssertEqual(pa[2].x, 5)
        XCTAssertEqual(pa[2].y, 6)
    }

    func testFromDictMissingNodesAreInvisibleNaN() {
        let skel = makeSkeleton()
        let pa = PointsArray.from(dict: ["thorax": [3, 4]], skeleton: skel)
        // head (0) and abdomen (2) are missing.
        XCTAssertFalse(pa[0].visible)
        XCTAssertTrue(pa[0].x.isNaN)
        XCTAssertTrue(pa[0].y.isNaN)

        XCTAssertTrue(pa[1].visible)
        XCTAssertEqual(pa[1].x, 3)
        XCTAssertEqual(pa[1].y, 4)

        XCTAssertFalse(pa[2].visible)
        XCTAssertTrue(pa[2].x.isNaN)
        XCTAssertTrue(pa[2].y.isNaN)
    }

    func testFromDictPresentNodesAreVisible() {
        let skel = makeSkeleton()
        let pa = PointsArray.from(
            dict: ["head": [1, 2], "thorax": [3, 4], "abdomen": [5, 6]],
            skeleton: skel
        )
        for i in 0..<pa.count {
            XCTAssertTrue(pa[i].visible)
        }
    }

    func testFromDictWithNaNValueIsInvisible() {
        let skel = makeSkeleton()
        let pa = PointsArray.from(dict: ["head": [Float.nan, 2]], skeleton: skel)
        XCTAssertFalse(pa[0].visible)
    }

    // MARK: - Round-trip via node-based subscript

    func testFromDictRoundTripsViaNodeSubscript() {
        let skel = makeSkeleton()
        let pa = PointsArray.from(
            dict: ["head": [10, 20], "abdomen": [50, 60]],
            skeleton: skel
        )
        let head = skel.node(named: "head")!
        let abdomen = skel.node(named: "abdomen")!
        XCTAssertEqual(pa[head].x, 10)
        XCTAssertEqual(pa[head].y, 20)
        XCTAssertEqual(pa[abdomen].x, 50)
        XCTAssertEqual(pa[abdomen].y, 60)
    }

    func testFromDictRoundTripsViaNameSubscript() {
        let skel = makeSkeleton()
        let pa = PointsArray.from(dict: ["thorax": [7, 8]], skeleton: skel)
        XCTAssertEqual(pa["thorax"].x, 7)
        XCTAssertEqual(pa["thorax"].y, 8)
        XCTAssertTrue(pa["thorax"].visible)
    }
}
