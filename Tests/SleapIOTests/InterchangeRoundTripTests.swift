import XCTest
@testable import SleapIO

/// Cross-format round-trip tests: Swift write -> Swift read for each writable format.
///
/// Each test builds a comprehensive Labels object, exports it, re-imports it,
/// and verifies the subset that the target format preserves. Losses are documented
/// explicitly per the Phase 3 spec (P01).
final class InterchangeRoundTripTests: XCTestCase {

    // MARK: - Shared test data builder

    /// Build a comprehensive Labels object for round-trip testing.
    ///
    /// Contains:
    /// - 2 videos with known dimensions
    /// - skeleton with 3 nodes and 2 edges
    /// - 2 frames (one per video)
    /// - frame 0: 1 user instance + 1 predicted instance
    /// - frame 1: 1 user instance with a track
    /// - 1 track
    private func makeTestLabels() -> (labels: Labels, skeleton: Skeleton) {
        let skeleton = Skeleton(name: "animal", nodes: [
            Node(name: "nose"),
            Node(name: "left_ear"),
            Node(name: "right_ear"),
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])
        skeleton.addEdge(from: skeleton.nodes[1], to: skeleton.nodes[2])

        let track = Track(name: "animal_0")

        let video0 = Video(filename: "video_a.png")
        video0.frameSize = (height: 480, width: 640, channels: 3)

        let video1 = Video(filename: "video_b.png")
        video1.frameSize = (height: 480, width: 640, channels: 3)

        // Frame 0: user instance + predicted instance
        let userPoints0 = PointsArray(points: [
            Point(x: 100.5, y: 200.5, visible: true, complete: true),
            Point(x: 150.0, y: 250.0, visible: true, complete: true),
            Point(x: 200.0, y: 300.0, visible: false, complete: false),
        ])
        let userInst0 = Instance(skeleton: skeleton, points: userPoints0)

        let predPoints0 = PredictedPointsArray(points: [
            PredictedPoint(x: 101.0, y: 201.0, visible: true, complete: true, score: 0.95),
            PredictedPoint(x: 151.0, y: 251.0, visible: true, complete: true, score: 0.88),
            PredictedPoint(x: 201.0, y: 301.0, visible: true, complete: true, score: 0.91),
        ])
        let predInst0 = PredictedInstance(skeleton: skeleton, points: predPoints0, score: 0.92)

        let frame0 = LabeledFrame(video: video0, frameIndex: 0, instances: [userInst0, predInst0])

        // Frame 1: user instance with track
        let userPoints1 = PointsArray(points: [
            Point(x: 300.0, y: 100.0, visible: true, complete: true),
            Point(x: 350.0, y: 150.0, visible: true, complete: true),
            Point(x: 400.0, y: 200.0, visible: true, complete: true),
        ])
        let userInst1 = Instance(skeleton: skeleton, points: userPoints1, track: track)
        let frame1 = LabeledFrame(video: video1, frameIndex: 0, instances: [userInst1])

        let store = EagerFrameStore(frames: [frame0, frame1])
        let labels = Labels(
            frameStore: store,
            videos: [video0, video1],
            skeletons: [skeleton],
            tracks: [track]
        )

        return (labels, skeleton)
    }

    /// Create a temp directory for test output.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_rt_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - COCO round-trip

    /// COCO JSON: write -> read -> verify instance count, coordinates, predicted scores.
    ///
    /// Preserved: instance count, coordinates, skeleton structure (nodes + edges via category),
    ///            predicted instance scores, visibility.
    /// Lost (C07): tracks, tracking scores, per-point prediction scores, from_predicted.
    func testCOCORoundTrip() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let (labels, _) = makeTestLabels()
        let outPath = dir.appendingPathComponent("coco_export.json").path

        try COCOCodec.write(labels, to: outPath)
        let reloaded = try COCOCodec.read(from: outPath)

        // Structure: 2 videos -> 2 images -> 2 frames
        XCTAssertEqual(reloaded.frameCount, 2, "Each image should become one frame")

        // Total instances: frame0 has 2, frame1 has 1 = 3 total
        let totalInstances = reloaded.reduce(0) { $0 + $1.instances.count }
        XCTAssertEqual(totalInstances, 3, "Total instance count should be preserved")

        // Verify skeleton reconstruction
        XCTAssertEqual(reloaded.skeletons.count, 1)
        XCTAssertEqual(reloaded.skeletons[0].nodes.count, 3)

        // Verify coordinates on first frame's first instance
        let frame0 = reloaded.first { $0.instances.count == 2 }
        XCTAssertNotNil(frame0, "Should have a frame with 2 instances")
        if let f0 = frame0 {
            // At least one instance should have coordinates near (100.5, 200.5)
            let hasMatchingCoord = f0.instances.contains { inst in
                let pt = inst.points[0]
                return abs(pt.x - 100.5) < 1.0 && abs(pt.y - 200.5) < 1.0
            }
            XCTAssertTrue(hasMatchingCoord, "User instance coordinates should be preserved")
        }

        // Verify predicted instance score is preserved
        let allPredicted = reloaded.flatMap { $0.predictedInstances }
        XCTAssertFalse(allPredicted.isEmpty, "Predicted instances should be preserved via score")
        if let pred = allPredicted.first {
            XCTAssertEqual(pred.score, 0.92, accuracy: 0.01, "Instance score should be preserved")
        }

        // Verify losses (C07)
        XCTAssertTrue(reloaded.tracks.isEmpty, "COCO drops tracks")
    }

    // MARK: - CSV round-trip

    /// CSV: write -> read -> verify instance count, coordinates, tracks, predicted instances.
    ///
    /// Preserved (V01-V06): instance count, coordinates, tracks by name, instance_type,
    ///                       instance_score, point_score, visibility.
    /// Lost (V07): skeleton edges, skeleton symmetries, from_predicted, suggestion frames.
    func testCSVRoundTrip() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let (labels, _) = makeTestLabels()
        let outPath = dir.appendingPathComponent("csv_export.csv").path

        try CSVCodec.write(labels, to: outPath)
        let reloaded = try CSVCodec.read(from: outPath)

        // Structure
        XCTAssertEqual(reloaded.frameCount, 2)
        XCTAssertEqual(reloaded.videos.count, 2)

        // Total instances preserved
        let totalInstances = reloaded.reduce(0) { $0 + $1.instances.count }
        XCTAssertEqual(totalInstances, 3)

        // Track preserved by name (V05)
        XCTAssertEqual(reloaded.tracks.count, 1)
        XCTAssertEqual(reloaded.tracks[0].name, "animal_0")

        // Predicted instance preserved (V04)
        let allPredicted = reloaded.flatMap { $0.predictedInstances }
        XCTAssertEqual(allPredicted.count, 1)
        if let pred = allPredicted.first {
            XCTAssertEqual(pred.score, 0.92, accuracy: 0.01, "Instance score should round-trip")
        }

        // Skeleton reconstructed but edgeless (V02)
        XCTAssertEqual(reloaded.skeletons.count, 1)
        XCTAssertEqual(reloaded.skeletons[0].nodes.count, 3)
        XCTAssertTrue(reloaded.skeletons[0].edges.isEmpty, "V02: CSV loses skeleton edges")

        // Coordinates preserved
        // Find the frame with the tracked instance
        let trackedFrame = reloaded.first { frame in
            frame.instances.contains { $0.track != nil }
        }
        XCTAssertNotNil(trackedFrame)
        if let tf = trackedFrame {
            let trackedInst = tf.instances.first { $0.track != nil }!
            XCTAssertEqual(trackedInst.points[0].x, 300.0, accuracy: 0.1)
            XCTAssertEqual(trackedInst.points[0].y, 100.0, accuracy: 0.1)
        }
    }

    // MARK: - Label Studio round-trip

    /// Label Studio: write -> read -> verify instance count, coordinates.
    ///
    /// Preserved (LJS02-LJS04): instance count, coordinates (via percentage conversion),
    ///                           user vs predicted distinction.
    /// Lost (LJS06): tracks, tracking scores, from_predicted, skeleton topology.
    func testLabelStudioRoundTrip() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let (labels, skeleton) = makeTestLabels()

        let mapping = LabelStudioCodec.SkeletonMapping(
            skeleton: skeleton,
            labelToNode: [
                "Nose": "nose",
                "Left Ear": "left_ear",
                "Right Ear": "right_ear",
            ]
        )

        let outPath = dir.appendingPathComponent("ls_export.json").path
        try LabelStudioCodec.write(labels, to: outPath, mapping: mapping)
        let reloaded = try LabelStudioCodec.read(from: outPath, mapping: mapping)

        // Structure: 2 tasks -> 2 frames
        XCTAssertEqual(reloaded.frameCount, 2)

        // Total instances preserved
        let totalInstances = reloaded.reduce(0) { $0 + $1.instances.count }
        XCTAssertEqual(totalInstances, 3)

        // Coordinates survive percentage conversion within tolerance
        // Find frame with 2 instances (frame 0)
        let frame0 = reloaded.first { $0.instances.count == 2 }
        XCTAssertNotNil(frame0)
        if let f0 = frame0 {
            let hasNearCoord = f0.instances.contains { inst in
                let pt = inst.points[0]
                return abs(pt.x - 100.5) < 2.0 && abs(pt.y - 200.5) < 2.0
            }
            XCTAssertTrue(hasNearCoord,
                           "Coordinates should survive percentage round-trip within tolerance")
        }

        // Losses (LJS06)
        XCTAssertTrue(reloaded.tracks.isEmpty, "LJS06: Label Studio drops tracks")
    }

    // MARK: - YOLO round-trip

    /// YOLO: write -> read -> verify instance count, coordinates.
    ///
    /// Preserved (Y03-Y04): instance count, coordinates (via normalization),
    ///                       visibility.
    /// Lost (Y06): tracks, instance scores, point scores, from_predicted.
    func testYOLORoundTrip() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let (labels, skeleton) = makeTestLabels()
        let config = YOLOCodec.Config(skeleton: skeleton)

        let datasetRoot = dir.appendingPathComponent("yolo_dataset").path
        try FileManager.default.createDirectory(
            atPath: datasetRoot, withIntermediateDirectories: true)

        try YOLOCodec.write(labels, to: datasetRoot, config: config)
        let reloaded = try YOLOCodec.read(from: datasetRoot, config: config)

        // Structure: 2 images -> 2 frames
        XCTAssertEqual(reloaded.frameCount, 2)

        // Total instances preserved
        let totalInstances = reloaded.reduce(0) { $0 + $1.instances.count }
        XCTAssertEqual(totalInstances, 3)

        // Coordinates survive normalization within tolerance
        let frame0 = reloaded.first { $0.instances.count == 2 }
        XCTAssertNotNil(frame0)
        if let f0 = frame0 {
            let hasNearCoord = f0.instances.contains { inst in
                let pt = inst.points[0]
                return abs(pt.x - 100.5) < 2.0 && abs(pt.y - 200.5) < 2.0
            }
            XCTAssertTrue(hasNearCoord,
                           "Coordinates should survive normalization round-trip within tolerance")
        }

        // Losses (Y06)
        XCTAssertTrue(reloaded.tracks.isEmpty, "Y06: YOLO drops tracks")

        // Predicted instances lose their scores -> become plain Instance
        let allPredicted = reloaded.flatMap { $0.predictedInstances }
        XCTAssertTrue(allPredicted.isEmpty,
                      "Y06: YOLO drops scores, so predicted instances become plain instances")
    }

    // MARK: - Cross-format coordinate fidelity

    /// Verify that all writable formats preserve coordinates within acceptable tolerance.
    ///
    /// This tests the fundamental guarantee that pose data survives interchange.
    func testAllFormatsPreserveCoordinatesFidelity() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton = Skeleton(name: "simple", nodes: [
            Node(name: "a"),
            Node(name: "b"),
        ])

        let video = Video(filename: "fidelity_test.png")
        video.frameSize = (height: 1000, width: 1000, channels: 3)

        let testCoords: [(Float, Float)] = [
            (0.0, 0.0),
            (500.0, 500.0),
            (999.0, 999.0),
        ]

        for (idx, (tx, ty)) in testCoords.enumerated() {
            let points = PointsArray(points: [
                Point(x: tx, y: ty, visible: true),
                Point(x: tx + 10, y: ty + 10, visible: true),
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

            // COCO
            let cocoPath = dir.appendingPathComponent("fidelity_coco_\(idx).json").path
            try COCOCodec.write(labels, to: cocoPath)
            let cocoReloaded = try COCOCodec.read(from: cocoPath)
            let cocoPt = cocoReloaded[0].instances[0].points[0]
            XCTAssertEqual(cocoPt.x, tx, accuracy: 0.5,
                           "COCO should preserve x=\(tx) within 0.5px")
            XCTAssertEqual(cocoPt.y, ty, accuracy: 0.5,
                           "COCO should preserve y=\(ty) within 0.5px")

            // CSV
            let csvPath = dir.appendingPathComponent("fidelity_csv_\(idx).csv").path
            try CSVCodec.write(labels, to: csvPath)
            let csvReloaded = try CSVCodec.read(from: csvPath)
            let csvPt = csvReloaded[0].instances[0].points[0]
            XCTAssertEqual(csvPt.x, tx, accuracy: 0.01,
                           "CSV should preserve x=\(tx) within float precision")
            XCTAssertEqual(csvPt.y, ty, accuracy: 0.01,
                           "CSV should preserve y=\(ty) within float precision")
        }
    }

    // MARK: - P03: Deterministic ordering

    /// P03: Verify that export ordering is deterministic across multiple writes.
    func testDeterministicOrdering() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let (labels, _) = makeTestLabels()

        // Write CSV twice and compare
        let csvPath1 = dir.appendingPathComponent("order_1.csv").path
        let csvPath2 = dir.appendingPathComponent("order_2.csv").path
        try CSVCodec.write(labels, to: csvPath1)
        try CSVCodec.write(labels, to: csvPath2)

        let data1 = try Data(contentsOf: URL(fileURLWithPath: csvPath1))
        let data2 = try Data(contentsOf: URL(fileURLWithPath: csvPath2))
        XCTAssertEqual(data1, data2, "P03: Repeated CSV exports should produce identical output")

        // Write COCO twice and compare
        let cocoPath1 = dir.appendingPathComponent("order_1.json").path
        let cocoPath2 = dir.appendingPathComponent("order_2.json").path
        try COCOCodec.write(labels, to: cocoPath1)
        try COCOCodec.write(labels, to: cocoPath2)

        let cocoData1 = try Data(contentsOf: URL(fileURLWithPath: cocoPath1))
        let cocoData2 = try Data(contentsOf: URL(fileURLWithPath: cocoPath2))
        XCTAssertEqual(cocoData1, cocoData2, "P03: Repeated COCO exports should produce identical output")
    }
}
