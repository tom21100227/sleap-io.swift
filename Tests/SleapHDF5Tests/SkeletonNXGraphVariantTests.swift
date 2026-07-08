import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// Regression tests for the sleap-io 0.5.x skeleton encoding variant used by the
/// `tracks/clip*.slp` fixtures.
///
/// Two format quirks combined to drop nodes/edges before the fix:
///   1. The NetworkX graph is wrapped in an `nx_graph` envelope (with sibling
///      `description`/`preview_image` fields) instead of living at the top level.
///   2. Link `source`/`target` are node *ids* (indices into the top-level superset
///      node list), not positional indices into the skeleton's own node array — so
///      subset/permuted skeletons resolved their edges to the wrong nodes.
final class SkeletonNXGraphVariantTests: XCTestCase {

    // MARK: - Self-contained decoder unit test (always runs)

    /// The exact structure emitted for `clip.2node.slp`: an `nx_graph` envelope
    /// whose two nodes reference superset indices 11 (head) and 4 (thorax), with a
    /// single edge whose source/target are the superset ids 4→11 (thorax→head).
    func testNXGraphEnvelopeWithSupersetIDEdgesDecodes() throws {
        let superset = [
            "forelegL4", "wingR", "hindlegR4", "eyeL", "thorax", "abdomen",
            "eyeR", "wingL", "forelegR4", "midlegL4", "midlegR4", "head", "hindlegL4",
        ]
        let dict: [String: Any] = [
            "description": NSNull(),
            "preview_image": NSNull(),
            "nx_graph": [
                "directed": true,
                "multigraph": true,
                "graph": ["name": "Skeleton-3", "num_edges_inserted": 12],
                "nodes": [["id": 11], ["id": 4]],
                "links": [
                    [
                        "edge_insert_idx": 0,
                        "key": 0,
                        "source": 4,
                        "target": 11,
                        "type": [
                            "py/reduce": [
                                ["py/type": "sleap.skeleton.EdgeType"],
                                ["py/tuple": [1]],
                            ]
                        ],
                    ]
                ],
            ],
        ]

        let skeleton = try SkeletonCodec.decodeFromNetworkX(dict, nodeNames: superset)

        XCTAssertEqual(skeleton.name, "Skeleton-3")
        XCTAssertEqual(skeleton.nodeNames, ["head", "thorax"])
        XCTAssertEqual(pairStrings(skeleton.edgeNames), ["thorax->head"])
    }

    // MARK: - Integration tests against on-disk fixtures (skipped if absent)

    func testClip2NodeSkeletonDecodesNodesAndEdge() async throws {
        let skeleton = try await loadSkeleton("clip.2node.slp")
        XCTAssertEqual(skeleton.name, "Skeleton-3")
        XCTAssertEqual(skeleton.nodeNames, ["head", "thorax"])
        XCTAssertEqual(pairStrings(skeleton.edgeNames), ["thorax->head"])
    }

    func testClipPredictionsSkeletonDecodesNodesAndEdge() async throws {
        let skeleton = try await loadSkeleton("clip.predictions.slp")
        XCTAssertEqual(skeleton.nodeNames, ["head", "thorax"])
        XCTAssertEqual(pairStrings(skeleton.edgeNames), ["thorax->head"])
    }

    func testClipSkeletonDecodesAllNodesAndEdges() async throws {
        let skeleton = try await loadSkeleton("clip.slp")
        XCTAssertEqual(
            skeleton.nodeNames,
            [
                "head", "thorax", "abdomen", "wingL", "wingR", "forelegL4",
                "forelegR4", "midlegL4", "midlegR4", "hindlegL4", "hindlegR4",
                "eyeL", "eyeR",
            ]
        )
        // Edges reference superset ids; verify a few that would have been scrambled
        // by positional resolution (superset is a permutation of node order here).
        XCTAssertEqual(
            pairStrings(skeleton.edgeNames),
            [
                "head->eyeL", "head->eyeR", "thorax->head", "thorax->abdomen",
                "thorax->wingL", "thorax->wingR", "thorax->forelegL4",
                "thorax->forelegR4", "thorax->midlegL4", "thorax->midlegR4",
                "thorax->hindlegL4", "thorax->hindlegR4",
            ]
        )
    }

    // MARK: - Helpers

    private func loadSkeleton(_ name: String) async throws -> Skeleton {
        let path = "/Users/than/work/sleap/tests/data/tracks/\(name)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Fixture '\(name)' not found at \(path)")
        }
        let labels = try await Labels.load(from: URL(fileURLWithPath: path), openVideos: false)
        guard let skeleton = labels.skeletons.first else {
            XCTFail("No skeleton decoded from \(name)")
            throw XCTSkip("No skeleton")
        }
        return skeleton
    }

    private func pairStrings(_ pairs: [(String, String)]) -> [String] {
        pairs.map { "\($0.0)->\($0.1)" }
    }
}
