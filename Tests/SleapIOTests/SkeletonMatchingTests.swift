import XCTest
@testable import SleapIO

/// E3.2: Tests for Skeleton flip/require/match helpers.
///
/// Upstream reference: Skeleton.get_flipped_node_inds / require_node /
/// match_nodes / matches / node_similarities.
final class SkeletonMatchingTests: XCTestCase {

    // MARK: - Helpers

    /// Build a skeleton from node names, optionally adding symmetry pairs.
    private func makeSkeleton(
        name: String = "skel",
        nodeNames: [String],
        symmetries: [(String, String)] = []
    ) -> Skeleton {
        let nodes = nodeNames.map { Node(name: $0) }
        let lookup = Dictionary(uniqueKeysWithValues: zip(nodeNames, nodes))
        let syms = symmetries.map { Symmetry(lookup[$0.0]!, lookup[$0.1]!) }
        return Skeleton(name: name, nodes: nodes, symmetries: syms)
    }

    // MARK: - getFlippedNodeInds

    func testGetFlippedNodeIndsSwapsSymmetricPair() {
        // Nodes A, B_left, B_right, C with symmetry (B_left, B_right).
        let skel = makeSkeleton(
            nodeNames: ["A", "B_left", "B_right", "C"],
            symmetries: [("B_left", "B_right")]
        )
        XCTAssertEqual(skel.getFlippedNodeInds(), [0, 2, 1, 3])
    }

    func testGetFlippedNodeIndsIdentityWhenNoSymmetries() {
        let skel = makeSkeleton(nodeNames: ["A", "B", "C", "D"])
        XCTAssertEqual(skel.getFlippedNodeInds(), [0, 1, 2, 3])
    }

    func testGetFlippedNodeIndsMultiplePairs() {
        // L1,R1,L2,R2,center with symmetries (L1,R1) and (L2,R2).
        let skel = makeSkeleton(
            nodeNames: ["L1", "R1", "L2", "R2", "center"],
            symmetries: [("L1", "R1"), ("L2", "R2")]
        )
        XCTAssertEqual(skel.getFlippedNodeInds(), [1, 0, 3, 2, 4])
    }

    func testGetFlippedNodeIndsEmptySkeleton() {
        let skel = makeSkeleton(nodeNames: [])
        XCTAssertEqual(skel.getFlippedNodeInds(), [])
    }

    // MARK: - requireNode

    func testRequireNodeReturnsExisting() {
        let skel = makeSkeleton(nodeNames: ["head", "tail"])
        let head = skel.node(named: "head")
        let required = skel.requireNode("head")
        XCTAssertNotNil(required)
        XCTAssertTrue(required === head, "Should return the existing node identity")
        XCTAssertEqual(skel.nodes.count, 2, "Should not add a duplicate node")
    }

    func testRequireNodeAddsWhenMissingByDefault() {
        let skel = makeSkeleton(nodeNames: ["head"])
        let added = skel.requireNode("neck")
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.name, "neck")
        XCTAssertEqual(skel.nodes.count, 2)
        XCTAssertTrue(skel.node(named: "neck") === added, "Added node should be retrievable by name")
    }

    func testRequireNodeReturnsNilWhenMissingAndNotAdding() {
        let skel = makeSkeleton(nodeNames: ["head"])
        let result = skel.requireNode("neck", addMissing: false)
        XCTAssertNil(result)
        XCTAssertEqual(skel.nodes.count, 1, "Should not add the node when addMissing is false")
        XCTAssertNil(skel.node(named: "neck"))
    }

    func testRequireNodeReturnsExistingEvenWhenAddMissingFalse() {
        let skel = makeSkeleton(nodeNames: ["head"])
        let head = skel.node(named: "head")
        let result = skel.requireNode("head", addMissing: false)
        XCTAssertTrue(result === head)
        XCTAssertEqual(skel.nodes.count, 1)
    }

    // MARK: - matchNodes

    func testMatchNodesMapsOverlappingNames() {
        // Skeleton order: A, B, C, D.
        let skel = makeSkeleton(nodeNames: ["A", "B", "C", "D"])
        // Incoming order: C, A, Z (Z does not exist).
        let result = skel.matchNodes(["C", "A", "Z"])
        // C -> this index 2, old position 0; A -> this index 0, old position 1.
        XCTAssertEqual(result.newInds, [2, 0])
        XCTAssertEqual(result.oldInds, [0, 1])
    }

    func testMatchNodesIdenticalOrdering() {
        let skel = makeSkeleton(nodeNames: ["A", "B", "C"])
        let result = skel.matchNodes(["A", "B", "C"])
        XCTAssertEqual(result.newInds, [0, 1, 2])
        XCTAssertEqual(result.oldInds, [0, 1, 2])
    }

    func testMatchNodesNoOverlap() {
        let skel = makeSkeleton(nodeNames: ["A", "B"])
        let result = skel.matchNodes(["X", "Y"])
        XCTAssertEqual(result.newInds, [])
        XCTAssertEqual(result.oldInds, [])
    }

    // MARK: - matches

    func testMatchesSameNameSetDifferentOrder() {
        let a = makeSkeleton(nodeNames: ["A", "B", "C"])
        let b = makeSkeleton(nodeNames: ["C", "B", "A"])
        XCTAssertTrue(a.matches(b), "Same name set should match when order not required")
        XCTAssertFalse(
            a.matches(b, requireSameOrder: true),
            "Different order should not match when same order required"
        )
    }

    func testMatchesSameNameSetSameOrder() {
        let a = makeSkeleton(nodeNames: ["A", "B", "C"])
        let b = makeSkeleton(nodeNames: ["A", "B", "C"])
        XCTAssertTrue(a.matches(b))
        XCTAssertTrue(a.matches(b, requireSameOrder: true))
    }

    func testMatchesDifferentNameSet() {
        let a = makeSkeleton(nodeNames: ["A", "B", "C"])
        let b = makeSkeleton(nodeNames: ["A", "B"])
        XCTAssertFalse(a.matches(b))
        XCTAssertFalse(a.matches(b, requireSameOrder: true))
    }

    // MARK: - nodeSimilarity

    func testNodeSimilarityIdenticalIsOne() {
        let a = makeSkeleton(nodeNames: ["A", "B", "C"])
        let b = makeSkeleton(nodeNames: ["C", "B", "A"])
        XCTAssertEqual(a.nodeSimilarity(b), 1.0, accuracy: 1e-9)
    }

    func testNodeSimilarityDisjointIsZero() {
        let a = makeSkeleton(nodeNames: ["A", "B"])
        let b = makeSkeleton(nodeNames: ["X", "Y"])
        XCTAssertEqual(a.nodeSimilarity(b), 0.0, accuracy: 1e-9)
    }

    func testNodeSimilarityPartialOverlapIsJaccard() {
        // a = {A, B, C}, b = {B, C, D}
        // intersection = {B, C} (2), union = {A, B, C, D} (4) => 0.5
        let a = makeSkeleton(nodeNames: ["A", "B", "C"])
        let b = makeSkeleton(nodeNames: ["B", "C", "D"])
        XCTAssertEqual(a.nodeSimilarity(b), 0.5, accuracy: 1e-9)
    }

    func testNodeSimilarityBothEmptyIsZero() {
        let a = makeSkeleton(nodeNames: [])
        let b = makeSkeleton(nodeNames: [])
        // Empty union => define similarity as 0 (avoid divide-by-zero).
        XCTAssertEqual(a.nodeSimilarity(b), 0.0, accuracy: 1e-9)
    }
}
