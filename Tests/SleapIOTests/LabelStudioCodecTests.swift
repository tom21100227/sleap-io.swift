import XCTest
@testable import SleapIO

/// LJS01-LJS06: Label Studio JSON codec tests.
final class LabelStudioCodecTests: XCTestCase {

    // MARK: - Helpers

    /// Build a simple skeleton for Label Studio tests.
    private func makeTestSkeleton() -> Skeleton {
        Skeleton(name: "animal", nodes: [
            Node(name: "nose"),
            Node(name: "left_ear"),
            Node(name: "right_ear"),
        ])
    }

    /// Build a SkeletonMapping for the test skeleton.
    private func makeTestMapping(skeleton: Skeleton? = nil) -> LabelStudioCodec.SkeletonMapping {
        let skel = skeleton ?? makeTestSkeleton()
        return LabelStudioCodec.SkeletonMapping(
            skeleton: skel,
            labelToNode: [
                "Nose": "nose",
                "Left Ear": "left_ear",
                "Right Ear": "right_ear",
            ]
        )
    }

    /// Create a temp directory for test output, returning its URL.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_ls_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Minimal valid Label Studio JSON with one task, one annotation, one keypoint result.
    private func minimalTaskJSON(
        imagePath: String = "/data/local-files/img_001.png",
        originalWidth: Int? = 640,
        originalHeight: Int? = 480,
        xPercent: Double = 25.0,
        yPercent: Double = 50.0,
        keypointLabel: String = "Nose",
        parentID: String? = nil,
        usePredictions: Bool = false
    ) -> [[String: Any]] {
        var value: [String: Any] = [
            "x": xPercent,
            "y": yPercent,
            "keypointlabels": [keypointLabel],
        ]
        if let w = originalWidth { value["original_width"] = w }
        if let h = originalHeight { value["original_height"] = h }

        var result: [String: Any] = [
            "id": "result_1",
            "type": "keypointlabels",
            "value": value,
        ]
        if let pid = parentID {
            result["parentID"] = pid
        }

        let section = usePredictions ? "predictions" : "annotations"

        let task: [String: Any] = [
            "id": 1,
            "data": ["image": imagePath],
            section: [
                ["id": "ann_1", "result": [result]]
            ],
        ]
        return [task]
    }

    /// Write JSON data to a temp file and return the path.
    private func writeTempJSON(_ json: Any, dir: URL, filename: String = "tasks.json") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        let filePath = dir.appendingPathComponent(filename).path
        try data.write(to: URL(fileURLWithPath: filePath))
        return filePath
    }

    // MARK: - LJS01: Explicit skeleton mapping

    /// LJS01: Calling read without a mapping throws invalidSkeleton.
    func testLJS01_readWithoutMappingThrows() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let json = minimalTaskJSON()
        let path = try writeTempJSON(json, dir: dir)

        // Create a mapping with an empty labelToNode to simulate missing mapping
        let emptySkeleton = Skeleton(name: "empty", nodes: [])
        let emptyMapping = LabelStudioCodec.SkeletonMapping(
            skeleton: emptySkeleton,
            labelToNode: [:]
        )

        XCTAssertThrowsError(try LabelStudioCodec.read(from: path, mapping: emptyMapping)) { error in
            guard case SleapIOError.invalidSkeleton = error else {
                XCTFail("Expected invalidSkeleton, got \(error)")
                return
            }
        }
    }

    /// LJS01: Mapping with labels not present in skeleton throws invalidSkeleton.
    func testLJS01_inconsistentMappingThrows() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let json = minimalTaskJSON()
        let path = try writeTempJSON(json, dir: dir)

        let skeleton = makeTestSkeleton()
        // Map a LS label to a node name that does not exist in the skeleton
        let badMapping = LabelStudioCodec.SkeletonMapping(
            skeleton: skeleton,
            labelToNode: [
                "Nose": "nose",
                "Left Ear": "left_ear",
                "Right Ear": "NONEXISTENT_NODE",
            ]
        )

        XCTAssertThrowsError(try LabelStudioCodec.read(from: path, mapping: badMapping)) { error in
            guard case SleapIOError.invalidSkeleton = error else {
                XCTFail("Expected invalidSkeleton, got \(error)")
                return
            }
        }
    }

    // MARK: - LJS02: Task to frame mapping

    /// LJS02: Each task creates one Video and one LabeledFrame with frameIndex == 0.
    func testLJS02_taskCreatesVideoAndFrame() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let json = minimalTaskJSON()
        let path = try writeTempJSON(json, dir: dir)
        let mapping = makeTestMapping()

        let labels = try LabelStudioCodec.read(from: path, mapping: mapping)

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.frameCount, 1)
        XCTAssertEqual(labels[0].frameIndex, 0, "P07: Image-based import must set frameIndex == 0")
    }

    /// LJS02: Image path is resolved relative to the JSON file's directory.
    func testLJS02_imagePathResolvedRelative() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let relativeImagePath = "images/photo.png"
        let json = minimalTaskJSON(imagePath: relativeImagePath)
        let path = try writeTempJSON(json, dir: dir)
        let mapping = makeTestMapping()

        let labels = try LabelStudioCodec.read(from: path, mapping: mapping)

        // The Video.filename should be resolved relative to the JSON file
        let expectedPath = dir.appendingPathComponent(relativeImagePath).path
        XCTAssertEqual(labels.videos[0].filename, expectedPath)
    }

    // MARK: - LJS03: Result grouping

    /// LJS03: Results sharing the same parentID form one Instance.
    func testLJS03_resultsGroupedByParentID() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let sharedParentID = "parent_group_1"

        // Three keypoint results sharing one parentID -> one instance with 3 points
        let results: [[String: Any]] = [
            [
                "id": "r1", "type": "keypointlabels", "parentID": sharedParentID,
                "value": ["x": 10.0, "y": 20.0, "keypointlabels": ["Nose"],
                          "original_width": 640, "original_height": 480],
            ],
            [
                "id": "r2", "type": "keypointlabels", "parentID": sharedParentID,
                "value": ["x": 30.0, "y": 40.0, "keypointlabels": ["Left Ear"],
                          "original_width": 640, "original_height": 480],
            ],
            [
                "id": "r3", "type": "keypointlabels", "parentID": sharedParentID,
                "value": ["x": 50.0, "y": 60.0, "keypointlabels": ["Right Ear"],
                          "original_width": 640, "original_height": 480],
            ],
        ]

        let task: [String: Any] = [
            "id": 1,
            "data": ["image": "img.png"],
            "annotations": [["id": "ann_1", "result": results]],
        ]
        let path = try writeTempJSON([task], dir: dir)
        let mapping = makeTestMapping()

        let labels = try LabelStudioCodec.read(from: path, mapping: mapping)

        XCTAssertEqual(labels[0].instances.count, 1, "Results with same parentID should form one Instance")
    }

    /// LJS03: Results without parentID are grouped by their own id.
    func testLJS03_resultsWithoutParentIDGroupedByOwnID() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // Two results without parentID and different ids -> two separate instances
        let results: [[String: Any]] = [
            [
                "id": "r1", "type": "keypointlabels",
                "value": ["x": 10.0, "y": 20.0, "keypointlabels": ["Nose"],
                          "original_width": 640, "original_height": 480],
            ],
            [
                "id": "r2", "type": "keypointlabels",
                "value": ["x": 30.0, "y": 40.0, "keypointlabels": ["Nose"],
                          "original_width": 640, "original_height": 480],
            ],
        ]

        let task: [String: Any] = [
            "id": 1,
            "data": ["image": "img.png"],
            "annotations": [["id": "ann_1", "result": results]],
        ]
        let path = try writeTempJSON([task], dir: dir)
        let mapping = makeTestMapping()

        let labels = try LabelStudioCodec.read(from: path, mapping: mapping)

        XCTAssertEqual(labels[0].instances.count, 2,
                       "Results without parentID should each form separate instances")
    }

    // MARK: - LJS04: Coordinate mapping

    /// LJS04: Percentage coordinates convert to absolute using original_width/height.
    func testLJS04_percentageToAbsoluteConversion() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // x=25%, y=50% with original_width=640, original_height=480
        // Expected absolute: x=160, y=240
        let json = minimalTaskJSON(xPercent: 25.0, yPercent: 50.0)
        let path = try writeTempJSON(json, dir: dir)
        let mapping = makeTestMapping()

        let labels = try LabelStudioCodec.read(from: path, mapping: mapping)
        let inst = labels[0].instances[0]

        // "Nose" maps to node index 0
        let pt = inst.points[0]
        XCTAssertEqual(pt.x, 160.0, accuracy: 0.01, "25% of 640 = 160")
        XCTAssertEqual(pt.y, 240.0, accuracy: 0.01, "50% of 480 = 240")
    }

    /// LJS04: Missing original_width/height throws corruptData.
    func testLJS04_missingOriginalDimensionsThrows() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let json = minimalTaskJSON(originalWidth: nil, originalHeight: nil)
        let path = try writeTempJSON(json, dir: dir)
        let mapping = makeTestMapping()

        XCTAssertThrowsError(try LabelStudioCodec.read(from: path, mapping: mapping)) { error in
            guard case SleapIOError.corruptData = error else {
                XCTFail("Expected corruptData for missing dimensions, got \(error)")
                return
            }
        }
    }

    /// LJS04: Export converts absolute coordinates to percentage values.
    func testLJS04_exportAbsoluteToPercentage() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton = makeTestSkeleton()
        let video = Video(filename: "test_img.png")
        video.frameSize = (height: 480, width: 640, channels: 3)

        let points = PointsArray(points: [
            Point(x: 160, y: 240, visible: true),
            Point(x: 320, y: 120, visible: true),
            Point(x: 480, y: 360, visible: true),
        ])
        let inst = Instance(skeleton: skeleton, points: points)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        let outPath = dir.appendingPathComponent("export.json").path
        let mapping = makeTestMapping(skeleton: skeleton)
        try LabelStudioCodec.write(labels, to: outPath, mapping: mapping)

        // Re-read and verify coordinates round-trip
        let reloaded = try LabelStudioCodec.read(from: outPath, mapping: mapping)
        let reloadedPt = reloaded[0].instances[0].points[0]
        XCTAssertEqual(reloadedPt.x, 160.0, accuracy: 0.5, "Absolute coords should survive write->read")
        XCTAssertEqual(reloadedPt.y, 240.0, accuracy: 0.5)
    }

    // MARK: - LJS05: User vs predicted

    /// LJS05: Annotations section imports as Instance (not PredictedInstance).
    func testLJS05_annotationsImportAsInstance() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let json = minimalTaskJSON(usePredictions: false)
        let path = try writeTempJSON(json, dir: dir)
        let mapping = makeTestMapping()

        let labels = try LabelStudioCodec.read(from: path, mapping: mapping)
        let inst = labels[0].instances[0]
        XCTAssertFalse(inst is PredictedInstance, "Annotations should import as user Instance")
    }

    /// LJS05: Predictions section imports as PredictedInstance.
    func testLJS05_predictionsImportAsPredictedInstance() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let json = minimalTaskJSON(usePredictions: true)
        let path = try writeTempJSON(json, dir: dir)
        let mapping = makeTestMapping()

        let labels = try LabelStudioCodec.read(from: path, mapping: mapping)
        let inst = labels[0].instances[0]
        XCTAssertTrue(inst is PredictedInstance, "Predictions should import as PredictedInstance")
    }

    // MARK: - LJS06: Losses

    /// LJS06: Tracks are not preserved through Label Studio export.
    func testLJS06_tracksDroppedOnExport() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton = makeTestSkeleton()
        let video = Video(filename: "test.png")
        video.frameSize = (height: 480, width: 640, channels: 3)
        let track = Track(name: "animal_0")

        let points = PointsArray(points: [
            Point(x: 100, y: 200, visible: true),
            Point(x: 150, y: 250, visible: true),
            Point(x: 200, y: 300, visible: true),
        ])
        let inst = Instance(skeleton: skeleton, points: points, track: track)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )

        let outPath = dir.appendingPathComponent("export.json").path
        let mapping = makeTestMapping(skeleton: skeleton)
        try LabelStudioCodec.write(labels, to: outPath, mapping: mapping)

        let reloaded = try LabelStudioCodec.read(from: outPath, mapping: mapping)
        XCTAssertTrue(reloaded.tracks.isEmpty, "Tracks should be dropped on Label Studio export")
        XCTAssertNil(reloaded[0].instances[0].track, "Instance track should be nil after round-trip")
    }

    // MARK: - NaN point export

    /// P1 regression: Export with NaN points does not crash — NaN points are omitted.
    func testExportWithNaNPointsSucceeds() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton = makeTestSkeleton()
        let video = Video(filename: "test.png")
        video.frameSize = (height: 480, width: 640, channels: 3)

        // One visible point, two NaN (missing) points
        let points = PointsArray(points: [
            Point(x: 160, y: 240, visible: true),
            Point(x: .nan, y: .nan, visible: false),
            Point(x: .nan, y: .nan, visible: false),
        ])
        let inst = Instance(skeleton: skeleton, points: points)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(frameStore: store, videos: [video], skeletons: [skeleton], tracks: [])

        let outPath = dir.appendingPathComponent("export.json").path
        let mapping = makeTestMapping(skeleton: skeleton)

        // This must not crash (was throwing due to NaN in JSONSerialization)
        XCTAssertNoThrow(try LabelStudioCodec.write(labels, to: outPath, mapping: mapping))

        // Re-read: should have 1 instance with the visible point, NaN points filled back in
        let reloaded = try LabelStudioCodec.read(from: outPath, mapping: mapping)
        XCTAssertEqual(reloaded.frameCount, 1)
        let reInst = reloaded[0].instances[0]
        // The visible point should survive
        XCTAssertEqual(reInst.points[0].x, 160.0, accuracy: 0.5)
        // The NaN points should be NaN (not exported, so default NaN fill on import)
        XCTAssertTrue(reInst.points[1].x.isNaN, "Missing points should remain NaN after round-trip")
        XCTAssertTrue(reInst.points[2].x.isNaN)
    }

    // MARK: - Error handling

    /// P06: Nonexistent file throws fileNotFound.
    func testNonexistentFileThrows() {
        let mapping = makeTestMapping()
        XCTAssertThrowsError(try LabelStudioCodec.read(from: "/nonexistent/path.json", mapping: mapping)) { error in
            guard case SleapIOError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    /// P06: Malformed JSON throws corruptData.
    func testMalformedJSONThrows() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("bad.json").path
        try "this is not json{{{".write(toFile: path, atomically: true, encoding: .utf8)

        let mapping = makeTestMapping()
        XCTAssertThrowsError(try LabelStudioCodec.read(from: path, mapping: mapping)) { error in
            guard case SleapIOError.corruptData = error else {
                XCTFail("Expected corruptData, got \(error)")
                return
            }
        }
    }

    // MARK: - Round-trip

    /// Round-trip: write then read preserves coordinates within float precision.
    func testRoundTripPreservesCoordinates() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton = makeTestSkeleton()
        let video = Video(filename: "roundtrip.png")
        video.frameSize = (height: 480, width: 640, channels: 3)

        let points = PointsArray(points: [
            Point(x: 123.45, y: 67.89, visible: true),
            Point(x: 456.78, y: 321.0, visible: true),
            Point(x: 0.5, y: 479.5, visible: true),
        ])
        let inst = Instance(skeleton: skeleton, points: points)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        let outPath = dir.appendingPathComponent("roundtrip.json").path
        let mapping = makeTestMapping(skeleton: skeleton)
        try LabelStudioCodec.write(labels, to: outPath, mapping: mapping)
        let reloaded = try LabelStudioCodec.read(from: outPath, mapping: mapping)

        XCTAssertEqual(reloaded.frameCount, 1)
        XCTAssertEqual(reloaded[0].instances.count, 1)

        let original = labels[0].instances[0].points
        let decoded = reloaded[0].instances[0].points
        for i in 0..<original.count {
            XCTAssertEqual(decoded[i].x, original[i].x, accuracy: 1.0,
                           "X coordinate at node \(i) should survive round-trip within tolerance")
            XCTAssertEqual(decoded[i].y, original[i].y, accuracy: 1.0,
                           "Y coordinate at node \(i) should survive round-trip within tolerance")
        }
    }

    // MARK: - P02: Eager import

    /// P02: Interchange imports must be eager.
    func testImportIsEager() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let json = minimalTaskJSON()
        let path = try writeTempJSON(json, dir: dir)
        let mapping = makeTestMapping()

        let labels = try LabelStudioCodec.read(from: path, mapping: mapping)
        XCTAssertFalse(labels.isLazy, "P02: Interchange imports must be eager")
    }
}
