import XCTest
@testable import SleapIO

/// E3.1: Skeleton derived accessors (node_names / edge_inds / edge_names /
/// symmetry_inds / symmetry_names / contains), mirroring Python `Skeleton`.
final class SkeletonAccessorsTests: XCTestCase {

    /// A small skeleton: A, B_left, B_right, C with a left/right symmetry.
    private func makeSkeleton() -> (Skeleton, [Node]) {
        let nodes = ["A", "B_left", "B_right", "C"].map { Node(name: $0) }
        let skel = Skeleton(name: "test", nodes: nodes)
        skel.addEdge(from: nodes[0], to: nodes[1]) // A -> B_left
        skel.addEdge(from: nodes[0], to: nodes[2]) // A -> B_right
        skel.addEdge(from: nodes[1], to: nodes[3]) // B_left -> C
        skel.addSymmetry(nodes[1], nodes[2])       // B_left <-> B_right
        return (skel, nodes)
    }

    func testNodeNames() {
        let (skel, _) = makeSkeleton()
        XCTAssertEqual(skel.nodeNames, ["A", "B_left", "B_right", "C"])
    }

    func testEdgeInds() {
        let (skel, _) = makeSkeleton()
        XCTAssertEqual(skel.edgeInds.map { [$0.0, $0.1] }, [[0, 1], [0, 2], [1, 3]])
    }

    func testEdgeNames() {
        let (skel, _) = makeSkeleton()
        XCTAssertEqual(
            skel.edgeNames.map { [$0.0, $0.1] },
            [["A", "B_left"], ["A", "B_right"], ["B_left", "C"]]
        )
    }

    func testSymmetryInds() {
        let (skel, _) = makeSkeleton()
        XCTAssertEqual(skel.symmetryInds.map { [$0.0, $0.1] }, [[1, 2]])
    }

    func testSymmetryNamesFollowSortedInds() {
        let (skel, _) = makeSkeleton()
        XCTAssertEqual(skel.symmetryNames.map { [$0.0, $0.1] }, [["B_left", "B_right"]])
    }

    func testSymmetryIndsAreSortedRegardlessOfInsertionOrder() {
        let (skel, nodes) = makeSkeleton()
        // Insert a reversed-order symmetry C(3) <-> A(0); should normalize to (0, 3).
        skel.addSymmetry(nodes[3], nodes[0])
        XCTAssertTrue(skel.symmetryInds.contains { [$0.0, $0.1] == [0, 3] })
        XCTAssertFalse(skel.symmetryInds.contains { $0.0 > $0.1 })
    }

    func testContainsNodeNamed() {
        let (skel, _) = makeSkeleton()
        XCTAssertTrue(skel.contains(nodeNamed: "A"))
        XCTAssertFalse(skel.contains(nodeNamed: "Z"))
    }

    func testContainsNodeByIdentity() {
        let (skel, nodes) = makeSkeleton()
        XCTAssertTrue(skel.contains(nodes[0]))
        XCTAssertFalse(skel.contains(Node(name: "A"))) // distinct identity
    }

    func testEmptySkeletonAccessors() {
        let skel = Skeleton(name: "empty")
        XCTAssertEqual(skel.nodeNames, [])
        XCTAssertEqual(skel.edgeInds.count, 0)
        XCTAssertEqual(skel.symmetryInds.count, 0)
    }
}
