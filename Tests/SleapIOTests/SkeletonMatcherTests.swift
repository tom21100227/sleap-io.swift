import XCTest
@testable import SleapIO

/// E5.1: Tests for ``SkeletonMatcher`` and ``SkeletonMatchMethod``.
///
/// Upstream reference: `sleap_io.model.matching.SkeletonMatcher /
/// SkeletonMatchMethod` and `tests/model/test_matching.py::TestSkeletonMatcher`.
final class SkeletonMatcherTests: XCTestCase {

    // MARK: - Helpers

    /// Build a skeleton from node names, edges (by name), and symmetries (by name).
    private func makeSkeleton(
        name: String = "skel",
        nodeNames: [String],
        edges: [(String, String)] = [],
        symmetries: [(String, String)] = []
    ) -> Skeleton {
        let nodes = nodeNames.map { Node(name: $0) }
        let lookup = Dictionary(uniqueKeysWithValues: zip(nodeNames, nodes))
        let edgeList = edges.map { Edge(source: lookup[$0.0]!, destination: lookup[$0.1]!) }
        let syms = symmetries.map { Symmetry(lookup[$0.0]!, lookup[$0.1]!) }
        return Skeleton(name: name, nodes: nodes, edges: edgeList, symmetries: syms)
    }

    // MARK: - Enum

    func testMethodRawValues() {
        XCTAssertEqual(SkeletonMatchMethod.exact.rawValue, "exact")
        XCTAssertEqual(SkeletonMatchMethod.structure.rawValue, "structure")
        XCTAssertEqual(SkeletonMatchMethod.overlap.rawValue, "overlap")
        XCTAssertEqual(SkeletonMatchMethod.subset.rawValue, "subset")
    }

    func testMethodRoundTripsFromRawValue() {
        for method in SkeletonMatchMethod.allCases {
            XCTAssertEqual(SkeletonMatchMethod(rawValue: method.rawValue), method)
        }
    }

    // MARK: - Defaults

    func testDefaultConfiguration() {
        let matcher = SkeletonMatcher()
        XCTAssertEqual(matcher.method, .structure)
        XCTAssertFalse(matcher.requireSameOrder)
        XCTAssertEqual(matcher.minOverlap, 0.5, accuracy: 1e-9)
    }

    // MARK: - EXACT

    func testExactMatchSameOrderAndEdges() {
        let a = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let b = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let matcher = SkeletonMatcher(method: .exact)
        XCTAssertTrue(matcher.match(a, b))
    }

    func testExactRejectsDifferentOrder() {
        let a = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        // Same node names and edges, but reordered nodes.
        let c = makeSkeleton(
            nodeNames: ["abdomen", "thorax", "head"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let matcher = SkeletonMatcher(method: .exact)
        XCTAssertFalse(matcher.match(a, c))
    }

    func testExactRejectsDifferentEdges() {
        // Same node names and order, but different edge set.
        let a = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let b = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "abdomen")]
        )
        let matcher = SkeletonMatcher(method: .exact)
        XCTAssertFalse(matcher.match(a, b))
    }

    // MARK: - STRUCTURE

    func testStructureMatchesDifferentOrder() {
        let a = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let b = makeSkeleton(
            nodeNames: ["abdomen", "thorax", "head"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let matcher = SkeletonMatcher(method: .structure)
        XCTAssertTrue(matcher.match(a, b))
    }

    func testStructureRejectsDifferentNodes() {
        let a = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let c = makeSkeleton(
            nodeNames: ["head", "thorax", "tail"],
            edges: [("head", "thorax"), ("thorax", "tail")]
        )
        let matcher = SkeletonMatcher(method: .structure)
        XCTAssertFalse(matcher.match(a, c))
    }

    func testStructureRejectsDifferentEdgesSameNodes() {
        let a = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let b = makeSkeleton(
            nodeNames: ["abdomen", "thorax", "head"],
            edges: [("head", "abdomen")]
        )
        let matcher = SkeletonMatcher(method: .structure)
        XCTAssertFalse(matcher.match(a, b))
    }

    func testStructureRejectsDifferentSymmetriesSameNodesAndEdges() {
        // Python's Skeleton.matches also compares symmetry sets.
        let a = makeSkeleton(
            nodeNames: ["wingL", "wingR", "body"],
            edges: [("body", "wingL"), ("body", "wingR")],
            symmetries: [("wingL", "wingR")]
        )
        let b = makeSkeleton(
            nodeNames: ["wingL", "wingR", "body"],
            edges: [("body", "wingL"), ("body", "wingR")]
        )
        let matcher = SkeletonMatcher(method: .structure)
        XCTAssertFalse(matcher.match(a, b))
    }

    func testStructureMatchesEqualSymmetriesRegardlessOfOrder() {
        let a = makeSkeleton(
            nodeNames: ["wingL", "wingR", "body"],
            edges: [("body", "wingL"), ("body", "wingR")],
            symmetries: [("wingL", "wingR")]
        )
        // Reordered nodes and symmetry pair given in the opposite order.
        let b = makeSkeleton(
            nodeNames: ["body", "wingR", "wingL"],
            edges: [("body", "wingL"), ("body", "wingR")],
            symmetries: [("wingR", "wingL")]
        )
        let matcher = SkeletonMatcher(method: .structure)
        XCTAssertTrue(matcher.match(a, b))
    }

    func testStructureRequireSameOrderRejectsReorder() {
        let a = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let b = makeSkeleton(
            nodeNames: ["abdomen", "thorax", "head"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let matcher = SkeletonMatcher(method: .structure, requireSameOrder: true)
        XCTAssertFalse(matcher.match(a, b))
    }

    func testStructureRequireSameOrderAcceptsSameOrder() {
        let a = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let b = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        let matcher = SkeletonMatcher(method: .structure, requireSameOrder: true)
        XCTAssertTrue(matcher.match(a, b))
    }

    // MARK: - OVERLAP

    func testOverlapMatchesAtThreshold() {
        // {head, thorax, abdomen} vs {head, thorax, tail}:
        // intersection = 2, union = 4 => Jaccard 0.5 >= 0.5.
        let a = makeSkeleton(nodeNames: ["head", "thorax", "abdomen"])
        let b = makeSkeleton(nodeNames: ["head", "thorax", "tail"])
        let matcher = SkeletonMatcher(method: .overlap, minOverlap: 0.5)
        XCTAssertTrue(matcher.match(a, b))
    }

    func testOverlapRejectsBelowThreshold() {
        // Disjoint node sets => Jaccard 0.0 < 0.5.
        let a = makeSkeleton(nodeNames: ["head", "thorax", "abdomen"])
        let c = makeSkeleton(nodeNames: ["wing1", "wing2", "tail"])
        let matcher = SkeletonMatcher(method: .overlap, minOverlap: 0.5)
        XCTAssertFalse(matcher.match(a, c))
    }

    func testOverlapMatchesIdenticalNodeSets() {
        let a = makeSkeleton(nodeNames: ["a", "b", "c"])
        let b = makeSkeleton(nodeNames: ["c", "b", "a"])
        let matcher = SkeletonMatcher(method: .overlap, minOverlap: 0.5)
        XCTAssertTrue(matcher.match(a, b)) // Jaccard 1.0
    }

    func testOverlapHighThresholdRejectsPartial() {
        let a = makeSkeleton(nodeNames: ["head", "thorax", "abdomen"])
        let b = makeSkeleton(nodeNames: ["head", "thorax", "tail"]) // Jaccard 0.5
        let matcher = SkeletonMatcher(method: .overlap, minOverlap: 0.9)
        XCTAssertFalse(matcher.match(a, b))
    }

    func testOverlapIgnoresEdges() {
        // Overlap depends only on node-name sets, not edges.
        let a = makeSkeleton(
            nodeNames: ["head", "thorax"],
            edges: [("head", "thorax")]
        )
        let b = makeSkeleton(nodeNames: ["head", "thorax"])
        let matcher = SkeletonMatcher(method: .overlap, minOverlap: 1.0)
        XCTAssertTrue(matcher.match(a, b))
    }

    // MARK: - SUBSET

    func testSubsetMatchesWhenFirstIsSubset() {
        let a = makeSkeleton(nodeNames: ["head", "thorax"])
        let b = makeSkeleton(nodeNames: ["head", "thorax", "abdomen", "tail"])
        let matcher = SkeletonMatcher(method: .subset)
        XCTAssertTrue(matcher.match(a, b))
    }

    func testSubsetRejectsWhenNotSubset() {
        let a = makeSkeleton(nodeNames: ["head", "thorax"])
        let c = makeSkeleton(nodeNames: ["head", "wing"])
        let matcher = SkeletonMatcher(method: .subset)
        XCTAssertFalse(matcher.match(a, c))
    }

    func testSubsetIsDirectional() {
        let a = makeSkeleton(nodeNames: ["head", "thorax"])
        let b = makeSkeleton(nodeNames: ["head", "thorax", "abdomen", "tail"])
        let matcher = SkeletonMatcher(method: .subset)
        // Superset is not a subset of its subset.
        XCTAssertFalse(matcher.match(b, a))
    }

    func testSubsetMatchesEqualNodeSets() {
        let a = makeSkeleton(nodeNames: ["head", "thorax"])
        let b = makeSkeleton(nodeNames: ["thorax", "head"])
        let matcher = SkeletonMatcher(method: .subset)
        XCTAssertTrue(matcher.match(a, b))
    }

    // MARK: - matches alias

    func testMatchesAliasEqualsMatch() {
        let a = makeSkeleton(nodeNames: ["head", "thorax", "abdomen"])
        let b = makeSkeleton(nodeNames: ["head", "thorax", "tail"])
        for method in SkeletonMatchMethod.allCases {
            let matcher = SkeletonMatcher(method: method)
            XCTAssertEqual(matcher.matches(a, b), matcher.match(a, b),
                           "matches(_:_:) must alias match(_:_:) for \(method)")
        }
    }

    // MARK: - Method matrix

    /// Run every method against a fixed set of skeleton pairs and assert the
    /// full boolean matrix, mirroring `TestSkeletonMatcher` in Python.
    func testMethodMatrix() {
        // Reference skeleton: head-thorax-abdomen chain.
        let base = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        // Identical to base (same order, same edges).
        let identical = makeSkeleton(
            nodeNames: ["head", "thorax", "abdomen"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        // Same nodes and edges, different node order.
        let reordered = makeSkeleton(
            nodeNames: ["abdomen", "thorax", "head"],
            edges: [("head", "thorax"), ("thorax", "abdomen")]
        )
        // One node swapped out (tail for abdomen): Jaccard 2/4 = 0.5.
        let oneDifferent = makeSkeleton(
            nodeNames: ["head", "thorax", "tail"],
            edges: [("head", "thorax"), ("thorax", "tail")]
        )
        // Strict subset of base's nodes.
        let subsetNodes = makeSkeleton(nodeNames: ["head", "thorax"])

        // (method, left, right, expected)
        let cases: [(SkeletonMatchMethod, Skeleton, Skeleton, Bool)] = [
            // EXACT: only the byte-for-byte identical structure matches.
            (.exact, base, identical, true),
            (.exact, base, reordered, false),
            (.exact, base, oneDifferent, false),

            // STRUCTURE: order-independent, but nodes + edges must match.
            (.structure, base, identical, true),
            (.structure, base, reordered, true),
            (.structure, base, oneDifferent, false),

            // OVERLAP (default 0.5): identical and half-overlap match, subset (0.667) too.
            (.overlap, base, identical, true),
            (.overlap, base, oneDifferent, true),   // Jaccard 0.5 >= 0.5
            (.overlap, base, subsetNodes, true),     // 2/3 ~= 0.667 >= 0.5

            // SUBSET: directional node-set containment.
            (.subset, subsetNodes, base, true),
            (.subset, base, subsetNodes, false),
            (.subset, base, oneDifferent, false),
        ]

        for (method, left, right, expected) in cases {
            let matcher = SkeletonMatcher(method: method)
            XCTAssertEqual(
                matcher.match(left, right), expected,
                "\(method): expected \(expected) for \(left.nodeNames) vs \(right.nodeNames)"
            )
        }
    }
}
