import XCTest
@testable import SleapIO
@testable import SleapHDF5

final class SkeletonFileCodecTests: XCTestCase {

    func testJSONSaveLoadRoundTrip() throws {
        let skeleton = makeSkeleton()
        let url = tempURL(extension: "json")
        defer { try? FileManager.default.removeItem(at: url) }

        try SkeletonFileCodec.saveSkeleton(skeleton, to: url)
        let loaded = try SkeletonFileCodec.loadSkeleton(from: url)

        XCTAssertEqual(loaded.name, skeleton.name)
        XCTAssertEqual(loaded.nodeNames, skeleton.nodeNames)
        XCTAssertEqual(pairStrings(loaded.edgeNames), pairStrings(skeleton.edgeNames))
        XCTAssertEqual(pairStrings(loaded.symmetryNames), pairStrings(skeleton.symmetryNames))
    }

    func testTrainingConfigJSONExtractsFirstSkeleton() throws {
        let skeletonDict = SkeletonCodec.encodeToNetworkX(makeSkeleton())
        let config: [String: Any] = [
            "data": [
                "labels": [
                    "skeletons": [skeletonDict]
                ]
            ],
            "model": [
                "heads": [:]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let url = tempURL(extension: "json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let loaded = try SkeletonFileCodec.loadSkeleton(from: url)

        XCTAssertEqual(loaded.name, "animal")
        XCTAssertEqual(loaded.nodeNames, ["head", "body", "left_eye", "right_eye"])
        XCTAssertEqual(pairStrings(loaded.edgeNames), ["head->body"])
        XCTAssertEqual(pairStrings(loaded.symmetryNames), ["left_eye->right_eye"])
    }

    func testYAMLIsExplicitlyUnsupported() throws {
        let url = tempURL(extension: "yaml")

        XCTAssertThrowsError(try SkeletonFileCodec.saveSkeleton(makeSkeleton(), to: url)) { error in
            guard case SleapIOError.unsupportedFormat(let message) = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
            XCTAssertTrue(message.contains("YAML skeleton files are not supported"))
        }
    }

    private func makeSkeleton() -> Skeleton {
        let skeleton = Skeleton(name: "animal", nodes: [
            Node(name: "head"),
            Node(name: "body"),
            Node(name: "left_eye"),
            Node(name: "right_eye")
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])
        skeleton.addSymmetry(skeleton.nodes[2], skeleton.nodes[3])
        return skeleton
    }

    private func pairStrings(_ pairs: [(String, String)]) -> [String] {
        pairs.map { "\($0.0)->\($0.1)" }
    }

    private func tempURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_skeleton_codec_\(UUID().uuidString).\(ext)")
    }
}
