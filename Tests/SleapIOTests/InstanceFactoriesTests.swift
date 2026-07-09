import XCTest
import simd
@testable import SleapIO

/// E2.3: Instance.empty() / from(numpy:) factories, plus the PredictedInstance
/// variants. Mirrors Python `Instance.empty` / `Instance.from_numpy` and
/// `PredictedInstance.empty(score=)` / `PredictedInstance.from_numpy`.
final class InstanceFactoriesTests: XCTestCase {

    private func skel3() -> (Skeleton, [Node]) {
        let nodes = ["a", "b", "c"].map { Node(name: $0) }
        return (Skeleton(name: "s", nodes: nodes), nodes)
    }

    // MARK: - Instance.empty

    func testEmptyInstanceHasNodeCountAllInvisible() {
        let (skel, _) = skel3()
        let inst = Instance.empty(skeleton: skel)
        XCTAssertEqual(inst.points.count, skel.nodes.count)
        XCTAssertTrue(inst.isEmpty, "empty() should produce an all-invisible instance")
        XCTAssertEqual(inst.nVisible, 0)
        for v in inst.points.visibility {
            XCTAssertFalse(v)
        }
        // numpy() of an empty instance is all-NaN rows.
        for row in inst.numpy() {
            XCTAssertTrue(row[0].isNaN && row[1].isNaN)
        }
    }

    func testEmptyInstanceAttachesSkeletonAndTrack() {
        let (skel, _) = skel3()
        let track = Track(name: "t0")
        let inst = Instance.empty(skeleton: skel, track: track)
        XCTAssertTrue(inst.skeleton === skel)
        XCTAssertTrue(inst.track === track)
        // Skeleton attached for node-based subscript access.
        XCTAssertTrue(inst.points.skeleton === skel)
    }

    // MARK: - Instance.from(numpy:)

    func testFromNumpyRoundTrips() {
        let (skel, _) = skel3()
        let coords: [[Float]] = [[0, 0], [10, 20], [.nan, .nan]]
        let inst = Instance.from(numpy: coords, skeleton: skel)

        XCTAssertEqual(inst.points.count, 3)
        XCTAssertTrue(inst.points.visibility[0])
        XCTAssertTrue(inst.points.visibility[1])
        XCTAssertFalse(inst.points.visibility[2], "NaN row should be invisible")

        // Round-trip through numpy(): finite rows preserved, NaN row stays NaN.
        let arr = inst.numpy()
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0], [0, 0])
        XCTAssertEqual(arr[1], [10, 20])
        XCTAssertTrue(arr[2][0].isNaN && arr[2][1].isNaN)
    }

    func testFromNumpyStoresFiniteCoordinates() {
        let (skel, _) = skel3()
        let coords: [[Float]] = [[1.5, 2.5], [.nan, .nan], [7, 8]]
        let inst = Instance.from(numpy: coords, skeleton: skel)
        XCTAssertEqual(inst.points.coordinates[0], 1.5)
        XCTAssertEqual(inst.points.coordinates[1], 2.5)
        XCTAssertEqual(inst.points.coordinates[4], 7)
        XCTAssertEqual(inst.points.coordinates[5], 8)
    }

    func testFromNumpyCarriesTrack() {
        let (skel, _) = skel3()
        let track = Track(name: "t1")
        let coords: [[Float]] = [[0, 0], [1, 1], [2, 2]]
        let inst = Instance.from(numpy: coords, skeleton: skel, track: track)
        XCTAssertTrue(inst.track === track)
    }

    // MARK: - PredictedInstance.empty

    func testPredictedEmptyHasScoreAndAllInvisible() {
        let (skel, _) = skel3()
        let pred = PredictedInstance.empty(skeleton: skel, score: 0.42)
        XCTAssertEqual(pred.points.count, skel.nodes.count)
        XCTAssertTrue(pred.isEmpty)
        XCTAssertEqual(pred.score, 0.42, accuracy: 1e-6)
        for s in pred.predictedPoints.scores {
            XCTAssertEqual(s, 0, accuracy: 1e-6)
        }
    }

    func testPredictedEmptyDefaultScoreZero() {
        let (skel, _) = skel3()
        let pred: PredictedInstance = .empty(skeleton: skel)
        XCTAssertEqual(pred.score, 0, accuracy: 1e-6)
    }

    // MARK: - PredictedInstance.from(numpy:)

    func testPredictedFromNumpyTwoColumns() {
        let (skel, _) = skel3()
        let coords: [[Float]] = [[1, 2], [3, 4], [.nan, .nan]]
        let pred = PredictedInstance.from(numpy: coords, skeleton: skel, score: 0.9)

        XCTAssertEqual(pred.score, 0.9, accuracy: 1e-6)
        XCTAssertTrue(pred.points.visibility[0])
        XCTAssertFalse(pred.points.visibility[2])

        // Round-trips with numpy(scores: false).
        let arr = pred.numpy(scores: false)
        XCTAssertEqual(arr[0], [1, 2])
        XCTAssertEqual(arr[1], [3, 4])
        XCTAssertTrue(arr[2][0].isNaN && arr[2][1].isNaN)
    }

    func testPredictedFromNumpyThreeColumnsCarriesPerPointScores() {
        let (skel, _) = skel3()
        // col 2 is the per-point score.
        let coords: [[Float]] = [[1, 2, 0.9], [3, 4, 0.8], [.nan, .nan, 0.1]]
        let pred = PredictedInstance.from(numpy: coords, skeleton: skel, score: 0.95)

        XCTAssertEqual(pred.predictedPoints.scores[0], 0.9, accuracy: 1e-6)
        XCTAssertEqual(pred.predictedPoints.scores[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(pred.predictedPoints.scores[2], 0.1, accuracy: 1e-6)

        // Round-trips with numpy(scores: true): xy + per-point score column.
        let arr = pred.numpy(scores: true)
        XCTAssertEqual(arr[0], [1, 2, 0.9])
        XCTAssertEqual(arr[1], [3, 4, 0.8])
        XCTAssertTrue(arr[2][0].isNaN && arr[2][1].isNaN)
        XCTAssertEqual(arr[2][2], 0.1, accuracy: 1e-6)
    }

    func testPredictedFromNumpyExplicitPointScoresOverrideColumn() {
        let (skel, _) = skel3()
        let coords: [[Float]] = [[1, 2], [3, 4], [5, 6]]
        let pred = PredictedInstance.from(
            numpy: coords, skeleton: skel, score: 0.5,
            pointScores: [0.11, 0.22, 0.33]
        )
        XCTAssertEqual(pred.predictedPoints.scores[0], 0.11, accuracy: 1e-6)
        XCTAssertEqual(pred.predictedPoints.scores[1], 0.22, accuracy: 1e-6)
        XCTAssertEqual(pred.predictedPoints.scores[2], 0.33, accuracy: 1e-6)
    }

    func testPredictedFromNumpyCarriesTrack() {
        let (skel, _) = skel3()
        let track = Track(name: "t2")
        let coords: [[Float]] = [[0, 0], [1, 1], [2, 2]]
        let pred: PredictedInstance = .from(numpy: coords, skeleton: skel, track: track)
        XCTAssertTrue(pred.track === track)
        XCTAssertTrue(pred.skeleton === skel)
        XCTAssertEqual(pred.predictedPoints.count, 3)
    }
}
