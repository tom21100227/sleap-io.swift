import XCTest
@testable import SleapIO
@testable import SleapHDF5

final class LabelsIOTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_labelsio_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        repoRoot().appendingPathComponent(relativePath)
    }

    private func makeLabelsForExport() -> Labels {
        let skeleton = Skeleton(name: "animal", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
            Node(name: "abdomen"),
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])
        skeleton.addEdge(from: skeleton.nodes[1], to: skeleton.nodes[2])

        let track = Track(name: "animal_0")
        let video = Video(filename: "frame_000.png")
        video.frameSize = (height: 480, width: 640, channels: 3)

        let points = PointsArray(points: [
            Point(x: 100, y: 200, visible: true, complete: true),
            Point(x: 150, y: 250, visible: true, complete: true),
            Point(x: 200, y: 300, visible: false, complete: true),
        ])
        let instance = Instance(skeleton: skeleton, points: points, track: track)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [instance])

        return Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )
    }

    func testLoadInfersCOCOFromJSONSchema() async throws {
        let url = fixtureURL("Tests/Fixtures/phase3/coco_single_skeleton/annotations.json")

        let labels = try await Labels.load(from: url)

        XCTAssertEqual(labels.frameCount, 3)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.skeletons[0].name, "fly")
        XCTAssertEqual(labels[0].instances.count, 2)
    }

    func testLoadEagerInfersCSVFromExtension() async throws {
        let url = fixtureURL("Tests/Fixtures/phase3/csv_multi_instance/multi_instance.csv")

        let labels = try await Labels.loadEager(from: url)

        XCTAssertEqual(labels.frameCount, 3)
        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels[0].instances.count, 2)
    }

    func testLoadInfersAlphaTrackerFromJSONSchema() async throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let entries: [[String: Any]] = [
            [
                "image_path": "clip.mp4",
                "frame_index": 0,
                "animal_id": 0,
                "keypoints": [[100.0, 200.0], [150.0, 250.0]],
            ],
            [
                "image_path": "clip.mp4",
                "frame_index": 5,
                "animal_id": 1,
                "keypoints": [[110.0, 210.0], [160.0, 260.0]],
                "confidence": 0.9,
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
        let url = dir.appendingPathComponent("alphatracker.json")
        try data.write(to: url)

        let labels = try await Labels.load(from: url)

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.frameCount, 2)
        XCTAssertEqual(labels.tracks.count, 2)
        XCTAssertEqual(labels[1].frameIndex, 5)
    }

    func testLoadLabelStudioWithoutMappingThrowsHelpfulError() async throws {
        let url = fixtureURL("Tests/Fixtures/phase3/labelstudio_keypoints/keypoints.json")

        do {
            _ = try await Labels.load(from: url)
            XCTFail("Label Studio load without a mapping should throw")
        } catch let error as SleapIOError {
            guard case .unsupportedFormat(let message) = error else {
                XCTFail("Expected unsupportedFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Label Studio"))
        }
    }

    func testSaveInfersCOCOForJSONOutput() async throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let outputURL = dir.appendingPathComponent("export.json")
        let labels = makeLabelsForExport()

        try await labels.save(to: outputURL)
        let reloaded = try await Labels.load(from: outputURL)

        XCTAssertEqual(reloaded.frameCount, 1)
        XCTAssertEqual(reloaded[0].instances.count, 1)
        XCTAssertTrue(reloaded.tracks.isEmpty, "COCO export should drop tracks")
    }

    func testSaveInfersCSVForCSVOutput() async throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let outputURL = dir.appendingPathComponent("export.csv")
        let labels = makeLabelsForExport()

        try await labels.save(to: outputURL)
        let reloaded = try await Labels.load(from: outputURL)

        XCTAssertEqual(reloaded.frameCount, 1)
        XCTAssertEqual(reloaded[0].instances.count, 1)
        XCTAssertEqual(reloaded.tracks.count, 1, "CSV export should preserve tracks")
    }

    func testSaveConfigDrivenFormatThrowsHelpfulError() async throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let outputURL = dir.appendingPathComponent("export.json")
        let labels = makeLabelsForExport()

        do {
            try await labels.save(to: outputURL, format: .labelStudio)
            XCTFail("Label Studio save without a mapping should throw")
        } catch let error as SleapIOError {
            guard case .unsupportedFormat(let message) = error else {
                XCTFail("Expected unsupportedFormat, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Label Studio"))
        }
    }
}
