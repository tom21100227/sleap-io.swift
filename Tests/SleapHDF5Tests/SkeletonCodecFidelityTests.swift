import XCTest
@testable import SleapIO
@testable import SleapHDF5

final class SkeletonCodecFidelityTests: XCTestCase {

    func testPythonJsonpickleBackrefsAndSymmetryLinksDecode() throws {
        let dict = pythonStyleSkeletonDict()

        let skeleton = try SkeletonCodec.decodeFromNetworkX(dict)

        XCTAssertEqual(skeleton.name, "fly")
        XCTAssertEqual(skeleton.nodeNames, ["head", "thorax", "left_wing", "right_wing"])
        XCTAssertEqual(pairStrings(skeleton.edgeNames), ["head->thorax"])
        XCTAssertEqual(pairStrings(skeleton.symmetryNames), ["left_wing->right_wing"])
    }

    func testEmbeddedBareEdgeTypeIDPreservesSecondSymmetryLink() throws {
        let dict = twoSymmetryEmbeddedSkeletonDict()

        let skeleton = try SkeletonCodec.decodeFromNetworkX(dict)

        XCTAssertEqual(pairStrings(skeleton.edgeNames), [])
        XCTAssertEqual(
            pairStrings(skeleton.symmetryNames),
            ["left_eye->right_eye", "left_wing->right_wing"]
        )
    }

    func testDecodeEncodeDecodePreservesTopology() throws {
        let decoded = try SkeletonCodec.decodeFromNetworkX(pythonStyleSkeletonDict())

        let encoded = SkeletonCodec.encodeToNetworkX(decoded)
        let roundTripped = try SkeletonCodec.decodeFromNetworkX(encoded)

        XCTAssertEqual(roundTripped.name, decoded.name)
        XCTAssertEqual(roundTripped.nodeNames, decoded.nodeNames)
        XCTAssertEqual(pairStrings(roundTripped.edgeNames), pairStrings(decoded.edgeNames))
        XCTAssertEqual(pairStrings(roundTripped.symmetryNames), pairStrings(decoded.symmetryNames))
    }

    private func pairStrings(_ pairs: [(String, String)]) -> [String] {
        pairs.map { "\($0.0)->\($0.1)" }
    }

    private func pythonStyleSkeletonDict() -> [String: Any] {
        [
            "directed": true,
            "multigraph": true,
            "graph": [
                "name": "fly",
                "symmetries": []
            ],
            "nodes": [
                [
                    "py/id": 10,
                    "py/state": ["name": "head", "weight": 1.0]
                ],
                [
                    "py/id": 11,
                    "py/state": ["name": "thorax", "weight": 1.0]
                ],
                [
                    "py/id": 12,
                    "py/state": ["name": "left_wing", "weight": 1.0]
                ],
                [
                    "py/id": 13,
                    "py/state": ["name": "right_wing", "weight": 1.0]
                ]
            ],
            "links": [
                [
                    "source": ["py/id": 10],
                    "target": ["py/id": 11],
                    "key": 0,
                    "type": [
                        "py/id": 20,
                        "py/reduce": [
                            ["py/type": "sleap.skeleton.EdgeType"],
                            ["py/tuple": [1]]
                        ]
                    ]
                ],
                [
                    "source": ["py/id": 12],
                    "target": ["py/id": 13],
                    "key": 0,
                    "type": [
                        "py/reduce": [
                            ["py/type": "sleap.skeleton.EdgeType"],
                            ["py/tuple": [2]]
                        ]
                    ]
                ]
            ]
        ]
    }

    private func twoSymmetryEmbeddedSkeletonDict() -> [String: Any] {
        [
            "directed": true,
            "multigraph": true,
            "graph": [
                "name": "fly",
                "symmetries": []
            ],
            "nodes": [
                [
                    "py/id": 10,
                    "py/state": ["name": "left_eye", "weight": 1.0]
                ],
                [
                    "py/id": 11,
                    "py/state": ["name": "right_eye", "weight": 1.0]
                ],
                [
                    "py/id": 12,
                    "py/state": ["name": "left_wing", "weight": 1.0]
                ],
                [
                    "py/id": 13,
                    "py/state": ["name": "right_wing", "weight": 1.0]
                ]
            ],
            "links": [
                [
                    "source": ["py/id": 10],
                    "target": ["py/id": 11],
                    "key": 0,
                    "type": [
                        "py/reduce": [
                            ["py/type": "sleap.skeleton.EdgeType"],
                            ["py/tuple": [2]]
                        ]
                    ]
                ],
                [
                    "source": ["py/id": 12],
                    "target": ["py/id": 13],
                    "key": 0,
                    "type": ["py/id": 2]
                ]
            ]
        ]
    }
}
