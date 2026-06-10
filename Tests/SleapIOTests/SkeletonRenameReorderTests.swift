import XCTest
@testable import SleapIO

/// E3.3: Skeleton node rename + reorder (with instance migration).
final class SkeletonRenameReorderTests: XCTestCase {

    private func abc() -> (Skeleton, [Node]) {
        let nodes = ["A", "B", "C"].map { Node(name: $0) }
        let skel = Skeleton(name: "s", nodes: nodes)
        skel.addEdge(from: nodes[0], to: nodes[1])
        return (skel, nodes)
    }

    func testRenameNode() throws {
        let (skel, nodes) = abc()
        try skel.renameNode("A", to: "X")
        XCTAssertEqual(skel.nodeNames, ["X", "B", "C"])
        XCTAssertTrue(skel.node(named: "X") === nodes[0])
        XCTAssertNil(skel.node(named: "A"))
        XCTAssertEqual(skel.index(of: nodes[0]), 0) // index unchanged
        // Edge still references the (renamed) node by reference.
        XCTAssertEqual(skel.edgeNames.first.map { [$0.0, $0.1] }, ["X", "B"])
    }

    func testRenameNodeThrows() {
        let (skel, _) = abc()
        XCTAssertThrowsError(try skel.renameNode("Z", to: "Q"))   // missing
        XCTAssertThrowsError(try skel.renameNode("A", to: "B"))   // collides
    }

    func testRenameNodesListAllowsSwap() throws {
        let (skel, _) = abc()
        try skel.renameNodes(["B", "A", "C"]) // swap first two names
        XCTAssertEqual(skel.nodeNames, ["B", "A", "C"])
        XCTAssertEqual(skel.node(named: "B")?.name, "B")
    }

    func testRenameNodesMap() throws {
        let (skel, _) = abc()
        try skel.renameNodes(["A": "X", "C": "Z"])
        XCTAssertEqual(skel.nodeNames, ["X", "B", "Z"])
    }

    func testReorderNodesMigratesInstancePoints() throws {
        let (skel, nodes) = abc()
        let inst = Instance(skeleton: skel)
        inst[nodes[0]] = Point(x: 0, y: 0, visible: true, complete: true)
        inst[nodes[1]] = Point(x: 1, y: 1, visible: true, complete: true)
        inst[nodes[2]] = Point(x: 2, y: 2, visible: true, complete: true)

        try skel.reorderNodes(["C", "A", "B"], migratingInstances: [inst])

        XCTAssertEqual(skel.nodeNames, ["C", "A", "B"])
        // point that was at C (2,2) is now index 0; A (0,0) index 1; B (1,1) index 2
        XCTAssertEqual(inst.points[0].x, 2)
        XCTAssertEqual(inst.points[1].x, 0)
        XCTAssertEqual(inst.points[2].x, 1)
        // node-name subscript still resolves correctly post-reorder
        XCTAssertEqual(inst[skel.node(named: "C")!].x, 2)
    }

    func testReorderNodesPermutesPredictedScores() throws {
        let (skel, nodes) = abc()
        var pts = PredictedPointsArray(count: 3)
        pts.skeleton = skel
        pts[0] = PredictedPoint(point: Point(x: 0, y: 0, visible: true, complete: true), score: 0.1)
        pts[1] = PredictedPoint(point: Point(x: 1, y: 1, visible: true, complete: true), score: 0.2)
        pts[2] = PredictedPoint(point: Point(x: 2, y: 2, visible: true, complete: true), score: 0.3)
        let pred = PredictedInstance(skeleton: skel, points: pts, score: 0.9)

        try skel.reorderNodes(["C", "A", "B"], migratingInstances: [pred])
        XCTAssertEqual(pred.predictedPoints.scores[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(pred.predictedPoints.scores[1], 0.1, accuracy: 1e-6)
        XCTAssertEqual(pred.predictedPoints.scores[2], 0.2, accuracy: 1e-6)
        _ = nodes
    }

    func testReorderNodesRejectsNonPermutation() {
        let (skel, _) = abc()
        XCTAssertThrowsError(try skel.reorderNodes(["A", "B"], migratingInstances: []))
        XCTAssertThrowsError(try skel.reorderNodes(["A", "B", "Z"], migratingInstances: []))
    }
}
