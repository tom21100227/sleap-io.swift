import XCTest
import simd
@testable import SleapIO

/// E2.1 / E2.2: Instance/Frame numpy export + geometry accessors.
final class InstanceAccessorsTests: XCTestCase {

    private func skel3() -> (Skeleton, [Node]) {
        let nodes = ["a", "b", "c"].map { Node(name: $0) }
        return (Skeleton(name: "s", nodes: nodes), nodes)
    }

    /// Build a user instance: a=(0,0) visible, b=(10,20) visible, c invisible.
    private func twoVisibleInstance() -> Instance {
        let (skel, nodes) = skel3()
        let inst = Instance(skeleton: skel)
        inst[nodes[0]] = Point(x: 0, y: 0, visible: true, complete: true)
        inst[nodes[1]] = Point(x: 10, y: 20, visible: true, complete: true)
        inst[nodes[2]] = Point(x: 99, y: 99, visible: false, complete: false)
        return inst
    }

    func testNumpyInvisibleAsNaN() {
        let inst = twoVisibleInstance()
        let arr = inst.numpy() // invisibleAsNaN: true by default
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0], [0, 0])
        XCTAssertEqual(arr[1], [10, 20])
        XCTAssertTrue(arr[2][0].isNaN && arr[2][1].isNaN, "invisible point should be NaN")
    }

    func testNumpyKeepsStoredCoordsWhenNotNaN() {
        let inst = twoVisibleInstance()
        let arr = inst.numpy(invisibleAsNaN: false)
        XCTAssertEqual(arr[2], [99, 99], "invisibleAsNaN:false returns stored coords")
    }

    func testNVisible() {
        XCTAssertEqual(twoVisibleInstance().nVisible, 2)
    }

    func testIsEmpty() {
        XCTAssertFalse(twoVisibleInstance().isEmpty)
        let (skel, _) = skel3()
        XCTAssertTrue(Instance(skeleton: skel).isEmpty, "all-invisible instance is empty")
    }

    func testCentroidXY() {
        let c = twoVisibleInstance().centroidXY
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.x, 5, accuracy: 1e-6)  // (0 + 10) / 2
        XCTAssertEqual(c!.y, 10, accuracy: 1e-6) // (0 + 20) / 2
    }

    func testCentroidXYNilWhenEmpty() {
        let (skel, _) = skel3()
        XCTAssertNil(Instance(skeleton: skel).centroidXY)
    }

    func testBoundingBoxArray() {
        let bb = twoVisibleInstance().boundingBoxArray()
        XCTAssertEqual(bb?[0], [0, 0])    // min
        XCTAssertEqual(bb?[1], [10, 20])  // max
    }

    func testBoundingBoxArrayNilWhenEmpty() {
        let (skel, _) = skel3()
        XCTAssertNil(Instance(skeleton: skel).boundingBoxArray())
    }

    func testPredictedInstanceNumpyWithScores() {
        let (skel, nodes) = skel3()
        var pts = PredictedPointsArray(count: 3)
        pts.skeleton = skel
        pts[nodes[0]] = PredictedPoint(point: Point(x: 1, y: 2, visible: true, complete: true), score: 0.9)
        pts[nodes[1]] = PredictedPoint(point: Point(x: 3, y: 4, visible: true, complete: true), score: 0.8)
        pts[nodes[2]] = PredictedPoint(point: Point(x: 0, y: 0, visible: false, complete: false), score: 0.1)
        let pred = PredictedInstance(skeleton: skel, points: pts, score: 0.95)

        let withScores = pred.numpy(scores: true)
        XCTAssertEqual(withScores[0], [1, 2, 0.9])
        XCTAssertEqual(withScores[1], [3, 4, 0.8])
        // invisible -> xy NaN, but score column preserved
        XCTAssertTrue(withScores[2][0].isNaN && withScores[2][1].isNaN)
        XCTAssertEqual(withScores[2][2], 0.1, accuracy: 1e-6)

        let noScores = pred.numpy(scores: false)
        XCTAssertEqual(noScores[0].count, 2)
    }

    func testLabeledFrameNumpyShape() {
        let inst1 = twoVisibleInstance()
        let inst2 = twoVisibleInstance()
        let frame = LabeledFrame(video: Video(filename: "v.mp4"), frameIndex: 0,
                                 instances: [inst1, inst2])
        let arr = frame.numpy()
        XCTAssertEqual(arr.count, 2)         // n_instances
        XCTAssertEqual(arr[0].count, 3)      // n_nodes
        XCTAssertEqual(arr[0][0].count, 2)   // xy
        XCTAssertEqual(arr[1][1], [10, 20])
    }
}
