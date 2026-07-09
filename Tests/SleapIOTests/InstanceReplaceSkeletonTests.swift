import XCTest
@testable import SleapIO

/// E2.4: Instance.replaceSkeleton / updateSkeleton.
final class InstanceReplaceSkeletonTests: XCTestCase {

    func testReplaceSkeletonByName() {
        let old = Skeleton(name: "old", nodes: ["A", "B", "C"].map { Node(name: $0) })
        let inst = Instance(skeleton: old)
        inst["A"] = Point(x: 1, y: 1, visible: true, complete: true)
        inst["B"] = Point(x: 2, y: 2, visible: true, complete: true)
        inst["C"] = Point(x: 3, y: 3, visible: true, complete: true)

        let new = Skeleton(name: "new", nodes: ["B", "C", "D"].map { Node(name: $0) })
        inst.replaceSkeleton(new)

        XCTAssertTrue(inst.skeleton === new)
        XCTAssertEqual(inst.points.count, 3)
        XCTAssertEqual(inst["B"].x, 2)        // carried over by name
        XCTAssertEqual(inst["C"].x, 3)
        XCTAssertFalse(inst["D"].visible)     // new node, no match -> invisible
        // node-name subscript routes through the new skeleton
        XCTAssertTrue(inst.points.skeleton === new)
    }

    func testReplaceSkeletonWithNameMap() {
        let old = Skeleton(name: "old", nodes: ["A", "B"].map { Node(name: $0) })
        let inst = Instance(skeleton: old)
        inst["A"] = Point(x: 5, y: 6, visible: true, complete: true)
        inst["B"] = Point(x: 7, y: 8, visible: true, complete: true)

        let new = Skeleton(name: "new", nodes: ["X", "B"].map { Node(name: $0) })
        inst.replaceSkeleton(new, nodeNamesMap: ["A": "X"])

        XCTAssertEqual(inst["X"].x, 5)  // A mapped to X
        XCTAssertEqual(inst["B"].x, 7)
    }

    func testPredictedReplaceSkeletonPreservesScores() {
        let old = Skeleton(name: "old", nodes: ["A", "B"].map { Node(name: $0) })
        var pts = PredictedPointsArray(count: 2)
        pts.skeleton = old
        pts["A"] = PredictedPoint(point: Point(x: 1, y: 1, visible: true, complete: true), score: 0.7)
        pts["B"] = PredictedPoint(point: Point(x: 2, y: 2, visible: true, complete: true), score: 0.8)
        let pred = PredictedInstance(skeleton: old, points: pts, score: 0.9)

        let new = Skeleton(name: "new", nodes: ["B", "A"].map { Node(name: $0) })
        pred.replaceSkeleton(new)

        XCTAssertTrue(pred.skeleton === new)
        XCTAssertEqual(pred.predictedPoints["A"].score, 0.7, accuracy: 1e-6)
        XCTAssertEqual(pred.predictedPoints["B"].score, 0.8, accuracy: 1e-6)
    }

    func testUpdateSkeletonNamesOnlyRepoints() {
        let skel = Skeleton(name: "s", nodes: ["A", "B"].map { Node(name: $0) })
        let inst = Instance(skeleton: skel)
        inst.updateSkeleton(namesOnly: true)
        XCTAssertTrue(inst.points.skeleton === skel)
    }
}
