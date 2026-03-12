import XCTest
@testable import SleapIO

/// Y01-Y06: YOLO pose dataset codec tests.
final class YOLOCodecTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestSkeleton() -> Skeleton {
        Skeleton(name: "animal", nodes: [
            Node(name: "nose"),
            Node(name: "left_ear"),
            Node(name: "right_ear"),
        ])
    }

    private func makeConfig(skeleton: Skeleton? = nil) -> YOLOCodec.Config {
        YOLOCodec.Config(skeleton: skeleton ?? makeTestSkeleton())
    }

    /// Create a minimal YOLO pose dataset directory with dataset.yaml, images, and labels.
    ///
    /// Returns the dataset root URL.
    ///
    /// - Parameters:
    ///   - imageWidth: Width for the placeholder images (used in label normalization).
    ///   - imageHeight: Height for the placeholder images.
    ///   - labelLines: Array of (imageName, [labelLine]) pairs. Each labelLine is a YOLO pose row.
    ///   - multiClass: If true, writes multiple class names (triggers Y02 unsupportedFormat).
    ///   - kptShape: The kpt_shape value, e.g. [3, 3] for 3 keypoints with visibility.
    private func makeYOLODataset(
        imageWidth: Int = 640,
        imageHeight: Int = 480,
        labelLines: [(String, [String])] = [],
        multiClass: Bool = false,
        kptShape: [Int] = [3, 3]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_yolo_test_\(UUID().uuidString)")
        let imagesDir = root.appendingPathComponent("images/train")
        let labelsDir = root.appendingPathComponent("labels/train")

        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: labelsDir, withIntermediateDirectories: true)

        // Write dataset.yaml
        var yamlContent: String
        if multiClass {
            yamlContent = """
            path: \(root.path)
            train: images/train
            names:
              0: cat
              1: dog
            kpt_shape: [\(kptShape.map(String.init).joined(separator: ", "))]
            """
        } else {
            yamlContent = """
            path: \(root.path)
            train: images/train
            names:
              0: animal
            kpt_shape: [\(kptShape.map(String.init).joined(separator: ", "))]
            """
        }
        try yamlContent.write(
            to: root.appendingPathComponent("dataset.yaml"),
            atomically: true, encoding: .utf8
        )

        // Write placeholder images and label files
        for (imageName, lines) in labelLines {
            // Create a minimal 1x1 PNG as placeholder (real tests would use actual images)
            // For now, write a marker file; the codec should derive dimensions from config or image.
            let imageFile = imagesDir.appendingPathComponent(imageName)
            try createPlaceholderImage(at: imageFile, width: imageWidth, height: imageHeight)

            // Write label file (same name, .txt extension)
            let baseName = (imageName as NSString).deletingPathExtension
            let labelFile = labelsDir.appendingPathComponent("\(baseName).txt")
            let labelContent = lines.joined(separator: "\n")
            try labelContent.write(to: labelFile, atomically: true, encoding: .utf8)
        }

        return root
    }

    /// Create a minimal placeholder image file. In real tests this would be a valid
    /// image so the codec can read dimensions. For TDD, we write enough for the codec
    /// to function or provide dimensions via the dataset.yaml kpt_shape.
    private func createPlaceholderImage(at url: URL, width: Int, height: Int) throws {
        // Write a simple PPM image (P6 format) so the codec can determine dimensions
        // PPM: "P6\n<width> <height>\n255\n" + RGB bytes
        var header = "P6\n\(width) \(height)\n255\n"
        var data = Data(header.utf8)
        data.append(Data(repeating: 128, count: width * height * 3))
        try data.write(to: url)
    }

    // MARK: - Y01: Explicit node-order requirement

    /// Y01: Reading without a config throws invalidSkeleton.
    func testY01_readWithoutConfigThrows() throws {
        let root = try makeYOLODataset()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Config with an empty skeleton (no nodes) simulates missing node order
        let emptySkeleton = Skeleton(name: "empty", nodes: [])
        let badConfig = YOLOCodec.Config(skeleton: emptySkeleton)

        XCTAssertThrowsError(try YOLOCodec.read(from: root.path, config: badConfig)) { error in
            guard case SleapIOError.invalidSkeleton = error else {
                XCTFail("Expected invalidSkeleton, got \(error)")
                return
            }
        }
    }

    // MARK: - Y02: Single-class first pass

    /// Y02: Multi-class dataset throws unsupportedFormat.
    func testY02_multiClassDatasetThrows() throws {
        let root = try makeYOLODataset(multiClass: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()

        XCTAssertThrowsError(try YOLOCodec.read(from: root.path, config: config)) { error in
            guard case SleapIOError.unsupportedFormat = error else {
                XCTFail("Expected unsupportedFormat for multi-class, got \(error)")
                return
            }
        }
    }

    // MARK: - Y03: Image to frame mapping

    /// Y03: Each image creates one Video and one LabeledFrame with frameIndex == 0.
    func testY03_imageCreatesVideoAndFrame() throws {
        // One image with one instance: class_id cx cy w h x1 y1 v1 x2 y2 v2 x3 y3 v3
        // Normalized center: 0.5, 0.5; bbox w/h: 0.2, 0.3
        // Keypoints (normalized): nose=(0.4, 0.5, 2), left_ear=(0.5, 0.4, 2), right_ear=(0.6, 0.6, 2)
        let label = "0 0.5 0.5 0.2 0.3 0.4 0.5 2 0.5 0.4 2 0.6 0.6 2"
        let root = try makeYOLODataset(labelLines: [("img_001.ppm", [label])])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        let labels = try YOLOCodec.read(from: root.path, config: config)

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.frameCount, 1)
        XCTAssertEqual(labels[0].frameIndex, 0, "P07: Image-based import sets frameIndex == 0")
    }

    /// Y03: Image path is resolved relative to the dataset root.
    func testY03_imagePathRelativeToRoot() throws {
        let label = "0 0.5 0.5 0.2 0.3 0.4 0.5 2 0.5 0.4 2 0.6 0.6 2"
        let root = try makeYOLODataset(labelLines: [("img_001.ppm", [label])])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        let labels = try YOLOCodec.read(from: root.path, config: config)

        let videoPath = labels.videos[0].filename
        XCTAssertTrue(videoPath.hasPrefix(root.path),
                      "Video path should be resolved relative to dataset root")
    }

    // MARK: - Y04: Coordinate mapping

    /// Y04: Normalized coordinates convert to absolute using image dimensions.
    func testY04_normalizedToAbsoluteConversion() throws {
        // Keypoints normalized: nose=(0.25, 0.5, 2)
        // Image: 640x480 -> absolute: x=160, y=240
        let label = "0 0.5 0.5 0.2 0.3 0.25 0.5 2 0.5 0.5 2 0.75 0.5 2"
        let root = try makeYOLODataset(
            imageWidth: 640, imageHeight: 480,
            labelLines: [("img.ppm", [label])]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        let labels = try YOLOCodec.read(from: root.path, config: config)

        let inst = labels[0].instances[0]
        let pt = inst.points[0]  // nose
        XCTAssertEqual(pt.x, 160.0, accuracy: 0.5, "0.25 * 640 = 160")
        XCTAssertEqual(pt.y, 240.0, accuracy: 0.5, "0.5 * 480 = 240")
    }

    /// Y04: Export converts absolute coordinates to normalized.
    func testY04_exportAbsoluteToNormalized() throws {
        let skeleton = makeTestSkeleton()
        let video = Video(filename: "test.ppm")
        video.frameSize = (height: 480, width: 640, channels: 3)

        let points = PointsArray(points: [
            Point(x: 160, y: 240, visible: true),
            Point(x: 320, y: 240, visible: true),
            Point(x: 480, y: 240, visible: true),
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

        let root = try makeYOLODataset(imageWidth: 640, imageHeight: 480, labelLines: [])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(skeleton: skeleton)
        try YOLOCodec.write(labels, to: root.path, config: config)

        // Re-read and verify coordinates survive the round-trip
        let reloaded = try YOLOCodec.read(from: root.path, config: config)
        let reloadedPt = reloaded[0].instances[0].points[0]
        XCTAssertEqual(reloadedPt.x, 160.0, accuracy: 1.0, "Absolute coords should survive round-trip")
        XCTAssertEqual(reloadedPt.y, 240.0, accuracy: 1.0)
    }

    // MARK: - Y05: Visibility mapping

    /// Y05: kpt_shape [N,3] — visibility <= 0 -> not labeled, > 0 -> visible.
    func testY05_kptShape3Visibility() throws {
        // 3 keypoints: visible(v=2), not-labeled(v=0), visible(v=1)
        let label = "0 0.5 0.5 0.2 0.3 0.25 0.5 2 0.5 0.5 0 0.75 0.5 1"
        let root = try makeYOLODataset(
            imageWidth: 640, imageHeight: 480,
            labelLines: [("img.ppm", [label])],
            kptShape: [3, 3]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        let labels = try YOLOCodec.read(from: root.path, config: config)
        let inst = labels[0].instances[0]

        XCTAssertTrue(inst.points.visibility[0], "v=2 should be visible")
        XCTAssertFalse(inst.points.visibility[1], "v=0 should not be visible (not labeled)")
        XCTAssertTrue(inst.points.visibility[2], "v=1 should be visible (v > 0)")
    }

    /// Y05: kpt_shape [N,2] — all listed points are visible.
    func testY05_kptShape2AllVisible() throws {
        // [N,2] format: no visibility column, just x,y per keypoint
        let label = "0 0.5 0.5 0.2 0.3 0.25 0.5 0.5 0.5 0.75 0.5"
        let root = try makeYOLODataset(
            imageWidth: 640, imageHeight: 480,
            labelLines: [("img.ppm", [label])],
            kptShape: [3, 2]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        let labels = try YOLOCodec.read(from: root.path, config: config)
        let inst = labels[0].instances[0]

        for i in 0..<inst.points.count {
            XCTAssertTrue(inst.points.visibility[i],
                          "All points in [N,2] format should be visible, but point \(i) is not")
        }
    }

    // MARK: - Y06: Losses

    /// Y06: Tracks are dropped on YOLO export.
    func testY06_tracksDroppedOnExport() throws {
        let skeleton = makeTestSkeleton()
        let video = Video(filename: "test.ppm")
        video.frameSize = (height: 480, width: 640, channels: 3)
        let track = Track(name: "animal_0")

        let points = PointsArray(points: [
            Point(x: 160, y: 240, visible: true),
            Point(x: 320, y: 240, visible: true),
            Point(x: 480, y: 240, visible: true),
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

        let root = try makeYOLODataset(imageWidth: 640, imageHeight: 480, labelLines: [])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(skeleton: skeleton)
        try YOLOCodec.write(labels, to: root.path, config: config)

        let reloaded = try YOLOCodec.read(from: root.path, config: config)
        XCTAssertTrue(reloaded.tracks.isEmpty, "Tracks should be dropped on YOLO export")
    }

    /// Y06: Instance and point scores are dropped on YOLO export.
    func testY06_scoresDroppedOnExport() throws {
        let skeleton = makeTestSkeleton()
        let video = Video(filename: "test.ppm")
        video.frameSize = (height: 480, width: 640, channels: 3)

        let predPoints = PredictedPointsArray(points: [
            PredictedPoint(x: 160, y: 240, visible: true, score: 0.95),
            PredictedPoint(x: 320, y: 240, visible: true, score: 0.88),
            PredictedPoint(x: 480, y: 240, visible: true, score: 0.91),
        ])
        let pred = PredictedInstance(skeleton: skeleton, points: predPoints, score: 0.92)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [pred])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        let root = try makeYOLODataset(imageWidth: 640, imageHeight: 480, labelLines: [])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(skeleton: skeleton)
        try YOLOCodec.write(labels, to: root.path, config: config)

        let reloaded = try YOLOCodec.read(from: root.path, config: config)
        // YOLO does not store scores, so re-imported instances should be plain Instance
        let inst = reloaded[0].instances[0]
        XCTAssertFalse(inst is PredictedInstance,
                       "Scores are lost on YOLO export; re-import should produce user Instance")
    }

    // MARK: - Multi-frame same-video export

    /// P1 regression: Multiple frames from the same Video get unique image files.
    func testExportMultiFrameSameVideoProducesUniqueFiles() throws {
        let skeleton = makeTestSkeleton()
        let video = Video(filename: "video.mp4")
        video.frameSize = (height: 480, width: 640, channels: 3)

        let pts1 = PointsArray(points: [
            Point(x: 100, y: 200, visible: true),
            Point(x: 150, y: 250, visible: true),
            Point(x: 200, y: 300, visible: true),
        ])
        let pts2 = PointsArray(points: [
            Point(x: 110, y: 210, visible: true),
            Point(x: 160, y: 260, visible: true),
            Point(x: 210, y: 310, visible: true),
        ])
        let frame0 = LabeledFrame(video: video, frameIndex: 0, instances: [Instance(skeleton: skeleton, points: pts1)])
        let frame1 = LabeledFrame(video: video, frameIndex: 5, instances: [Instance(skeleton: skeleton, points: pts2)])
        let store = EagerFrameStore(frames: [frame0, frame1])
        let labels = Labels(frameStore: store, videos: [video], skeletons: [skeleton], tracks: [])

        let root = try makeYOLODataset(imageWidth: 640, imageHeight: 480, labelLines: [])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(skeleton: skeleton)
        try YOLOCodec.write(labels, to: root.path, config: config)

        // Should have 2 distinct label files
        let labelsDir = root.appendingPathComponent("labels/train")
        let labelFiles = try FileManager.default.contentsOfDirectory(atPath: labelsDir.path).sorted()
        XCTAssertEqual(labelFiles.count, 2, "Two frames from one video should produce 2 label files")
        XCTAssertNotEqual(labelFiles[0], labelFiles[1], "Label file names must be unique")
    }

    // MARK: - Occluded point preservation

    /// P2 regression: Finite but visible=false points export as v=1, not v=0.
    func testExportOccludedPointsPreserved() throws {
        let skeleton = makeTestSkeleton()
        let video = Video(filename: "test.ppm")
        video.frameSize = (height: 480, width: 640, channels: 3)

        let points = PointsArray(points: [
            Point(x: 160, y: 240, visible: true),       // visible -> v=2
            Point(x: 320, y: 240, visible: false),      // occluded -> v=1 (not v=0!)
            Point(x: .nan, y: .nan, visible: false),     // missing -> v=0
        ])
        let inst = Instance(skeleton: skeleton, points: points)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(frameStore: store, videos: [video], skeletons: [skeleton], tracks: [])

        let root = try makeYOLODataset(imageWidth: 640, imageHeight: 480, labelLines: [])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(skeleton: skeleton)
        try YOLOCodec.write(labels, to: root.path, config: config)

        // Re-read: the occluded point should survive with finite coords
        let reloaded = try YOLOCodec.read(from: root.path, config: config)
        let reInst = reloaded[0].instances[0]
        // Point 0: visible
        XCTAssertTrue(reInst.points.visibility[0])
        XCTAssertEqual(reInst.points[0].x, 160.0, accuracy: 1.0)
        // Point 1: was occluded — should have finite coords (v=1 imports as visible per Y05)
        XCTAssertFalse(reInst.points[1].x.isNaN, "Occluded point with finite coords must survive export")
        XCTAssertEqual(reInst.points[1].x, 320.0, accuracy: 1.0)
        // Point 2: was NaN — should stay NaN
        XCTAssertTrue(reInst.points[2].x.isNaN, "Missing point should remain NaN")
    }

    // MARK: - Mixed-skeleton rejection

    /// P2 regression: Export with mixed skeletons throws unsupportedFormat.
    func testExportMixedSkeletonsThrows() throws {
        let skeleton1 = makeTestSkeleton()
        let skeleton2 = Skeleton(name: "other", nodes: [Node(name: "a"), Node(name: "b"), Node(name: "c")])
        let video = Video(filename: "test.ppm")
        video.frameSize = (height: 480, width: 640, channels: 3)

        let pts1 = PointsArray(points: [Point(x: 100, y: 200, visible: true), Point(x: 150, y: 250, visible: true), Point(x: 200, y: 300, visible: true)])
        let pts2 = PointsArray(points: [Point(x: 300, y: 400, visible: true), Point(x: 350, y: 450, visible: true), Point(x: 400, y: 500, visible: true)])
        let inst1 = Instance(skeleton: skeleton1, points: pts1)
        let inst2 = Instance(skeleton: skeleton2, points: pts2)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst1, inst2])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(frameStore: store, videos: [video], skeletons: [skeleton1, skeleton2], tracks: [])

        let root = try makeYOLODataset(imageWidth: 640, imageHeight: 480, labelLines: [])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(skeleton: skeleton1)
        XCTAssertThrowsError(try YOLOCodec.write(labels, to: root.path, config: config)) { error in
            guard case SleapIOError.unsupportedFormat = error else {
                XCTFail("Expected unsupportedFormat for mixed skeletons, got \(error)")
                return
            }
        }
    }

    // MARK: - Error handling

    /// P06: Nonexistent directory throws fileNotFound.
    func testNonexistentDirectoryThrows() {
        let config = makeConfig()
        XCTAssertThrowsError(try YOLOCodec.read(from: "/nonexistent/yolo_root", config: config)) { error in
            guard case SleapIOError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    /// P06: Missing dataset.yaml throws unsupportedFormat.
    func testMissingDatasetYamlThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_yolo_noyaml_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        XCTAssertThrowsError(try YOLOCodec.read(from: root.path, config: config)) { error in
            guard case SleapIOError.unsupportedFormat = error else {
                XCTFail("Expected unsupportedFormat for missing dataset.yaml, got \(error)")
                return
            }
        }
    }

    /// P06: Label file without accessible image dimensions is an error.
    func testMissingImageDimensionsThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_yolo_nodim_\(UUID().uuidString)")
        let imagesDir = root.appendingPathComponent("images/train")
        let labelsDir = root.appendingPathComponent("labels/train")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: labelsDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let yamlContent = """
        path: \(root.path)
        train: images/train
        names:
          0: animal
        kpt_shape: [3, 3]
        """
        try yamlContent.write(
            to: root.appendingPathComponent("dataset.yaml"),
            atomically: true, encoding: .utf8
        )

        // Write a label file but NO image file (or an unreadable one)
        let labelContent = "0 0.5 0.5 0.2 0.3 0.25 0.5 2 0.5 0.5 2 0.75 0.5 2"
        try labelContent.write(
            to: labelsDir.appendingPathComponent("orphan.txt"),
            atomically: true, encoding: .utf8
        )
        // No image file exists for this label

        let config = makeConfig()
        XCTAssertThrowsError(try YOLOCodec.read(from: root.path, config: config)) { error in
            // Could be corruptData or fileNotFound depending on implementation
            let isExpected: Bool
            switch error {
            case SleapIOError.corruptData, SleapIOError.fileNotFound, SleapIOError.videoError:
                isExpected = true
            default:
                isExpected = false
            }
            XCTAssertTrue(isExpected, "Expected an appropriate error for missing image, got \(error)")
        }
    }

    // MARK: - Round-trip

    /// Write then read preserves coordinates.
    func testRoundTripPreservesCoordinates() throws {
        let skeleton = makeTestSkeleton()
        let video = Video(filename: "roundtrip.ppm")
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

        let root = try makeYOLODataset(imageWidth: 640, imageHeight: 480, labelLines: [])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(skeleton: skeleton)
        try YOLOCodec.write(labels, to: root.path, config: config)
        let reloaded = try YOLOCodec.read(from: root.path, config: config)

        XCTAssertEqual(reloaded.frameCount, 1)
        XCTAssertEqual(reloaded[0].instances.count, 1)

        let original = labels[0].instances[0].points
        let decoded = reloaded[0].instances[0].points
        for i in 0..<original.count {
            XCTAssertEqual(decoded[i].x, original[i].x, accuracy: 1.0,
                           "X at node \(i) should survive YOLO round-trip")
            XCTAssertEqual(decoded[i].y, original[i].y, accuracy: 1.0,
                           "Y at node \(i) should survive YOLO round-trip")
        }
    }

    // MARK: - P02: Eager import

    /// P02: Interchange imports must be eager.
    func testImportIsEager() throws {
        let label = "0 0.5 0.5 0.2 0.3 0.4 0.5 2 0.5 0.4 2 0.6 0.6 2"
        let root = try makeYOLODataset(labelLines: [("img.ppm", [label])])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        let labels = try YOLOCodec.read(from: root.path, config: config)
        XCTAssertFalse(labels.isLazy, "P02: Interchange imports must be eager")
    }
}
