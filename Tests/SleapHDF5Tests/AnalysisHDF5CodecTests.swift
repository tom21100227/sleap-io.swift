import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// A01–A08, P401, P408: Analysis HDF5 codec tests.
///
/// These tests require .h5 fixture files in Tests/Fixtures/phase4/.
/// Tests will skip gracefully if fixtures are not available.
final class AnalysisHDF5CodecTests: XCTestCase {

    // MARK: - Helpers

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SleapHDF5Tests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
    }

    private func fixturePath(_ relativePath: String) -> String {
        packageRoot()
            .appendingPathComponent("Tests/Fixtures/phase4")
            .appendingPathComponent(relativePath)
            .path
    }

    private func requireFixture(_ name: String,
                                file: StaticString = #file,
                                line: UInt = #line) throws -> String {
        let path = fixturePath(name)
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Fixture '\(name)' not found — generate phase4 fixtures first")
        }
        return path
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_analysis_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - A01: Minimal import

    func testA01_minimalImport() throws {
        let path = try requireFixture("analysis_h5/analysis_minimal.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.frameCount, 3)
        XCTAssertEqual(labels.tracks.count, 2)
        XCTAssertEqual(labels.skeletons.count, 1)

        let skeleton = labels.skeletons[0]
        XCTAssertEqual(skeleton.nodes.count, 3)
        XCTAssertFalse(skeleton.edges.isEmpty, "Skeleton should have edges")
    }

    func testA01_videoPathPreserved() throws {
        let path = try requireFixture("analysis_h5/analysis_minimal.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        XCTAssertEqual(labels.videos[0].filename, "test_video.mp4")
    }

    // MARK: - A02: Shared identity

    func testA02_sharedIdentity() throws {
        let path = try requireFixture("analysis_h5/analysis_minimal.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        // All instances must share the exact same Skeleton object.
        let skeleton = labels.skeletons[0]
        for i in 0..<labels.frameCount {
            let frame = labels[i]
            for instance in frame.instances {
                XCTAssertTrue(instance.skeleton === skeleton,
                              "Instance at frame \(i) should share the same Skeleton object")
            }
        }

        // Track objects should be shared across frames.
        let trackSet = Set(labels.tracks.map { ObjectIdentifier($0) })
        for i in 0..<labels.frameCount {
            for instance in labels[i].instances {
                if let track = instance.track {
                    XCTAssertTrue(trackSet.contains(ObjectIdentifier(track)),
                                  "Track should be shared identity from labels.tracks")
                }
            }
        }
    }

    func testA02_nodeOrder() throws {
        let path = try requireFixture("analysis_h5/analysis_minimal.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        let nodeNames = labels.skeletons[0].nodes.map(\.name)
        XCTAssertEqual(nodeNames, ["head", "thorax", "tail"])
    }

    // MARK: - A03: Occupancy controls instances

    func testA03_occupancyControlsInstances() throws {
        let path = try requireFixture("analysis_h5/analysis_missing_tracks.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        // Frame 1 (index 1): only track 0 present → 1 instance
        let frame1 = labels[1]
        XCTAssertEqual(frame1.instances.count, 1,
                       "Frame 1 should have 1 instance (track 0 only)")

        // Frame 2 (index 2, if it exists): both tracks present → 2 instances
        if labels.frameCount > 2 {
            let frame2 = labels[2]
            XCTAssertEqual(frame2.instances.count, 2,
                           "Frame 2 should have 2 instances (both tracks)")
        }
    }

    func testA03_absentTrackNoInstance() throws {
        let path = try requireFixture("analysis_h5/analysis_missing_tracks.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        // Track 1 should have no instance at frames 1 and 3 (indices 1, 3).
        let track1 = labels.tracks.first { $0.name.contains("1") }
        XCTAssertNotNil(track1, "Should have a track for animal 1")

        for frameIdx in [1, 3] where frameIdx < labels.frameCount {
            let frame = labels[frameIdx]
            let instancesForTrack1 = frame.instances.filter { $0.track === track1 }
            XCTAssertTrue(instancesForTrack1.isEmpty,
                          "Track 1 should be absent at frame index \(frameIdx)")
        }
    }

    // MARK: - A04: Scores import

    func testA04_scoresImport() throws {
        let path = try requireFixture("analysis_h5/analysis_scores.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        // All instances should be PredictedInstance since scores are present.
        let frame = labels[0]
        XCTAssertFalse(frame.instances.isEmpty, "First frame should have instances")

        for instance in frame.instances {
            guard let predicted = instance as? PredictedInstance else {
                XCTFail("Instance should be PredictedInstance when scores are present")
                continue
            }
            // Instance score should be non-negative.
            XCTAssertGreaterThanOrEqual(predicted.score, 0)

            // Per-point scores should be populated.
            for i in 0..<predicted.predictedPoints.count {
                XCTAssertGreaterThanOrEqual(predicted.predictedPoints[i].score, 0)
            }

            // Tracking score should be present.
            XCTAssertNotNil(predicted.trackingScore)
        }
    }

    func testA04_noScoresMeansUserInstance() throws {
        let path = try requireFixture("analysis_h5/analysis_minimal.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        // Without score datasets, instances should be plain Instance (not PredictedInstance).
        for i in 0..<labels.frameCount {
            for instance in labels[i].instances {
                XCTAssertFalse(instance is PredictedInstance,
                               "Instance should be plain Instance without score datasets")
            }
        }
    }

    // MARK: - A05: Edges

    func testA05_edgesPreserved() throws {
        let path = try requireFixture("analysis_h5/analysis_minimal.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        let skeleton = labels.skeletons[0]
        XCTAssertEqual(skeleton.edges.count, 2)

        let edgePairs = skeleton.edges.map { ($0.source.name, $0.destination.name) }
        XCTAssertTrue(edgePairs.contains(where: { $0.0 == "head" && $0.1 == "thorax" }),
                      "Should have head→thorax edge")
        XCTAssertTrue(edgePairs.contains(where: { $0.0 == "thorax" && $0.1 == "tail" }),
                      "Should have thorax→tail edge")
    }

    func testA05_noEdgesProducesEdgeless() throws {
        let path = try requireFixture("analysis_h5/analysis_no_edges.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        XCTAssertTrue(labels.skeletons[0].edges.isEmpty,
                      "Skeleton should have no edges when edge dataset is absent")
    }

    // MARK: - A06: Multi-skeleton export throws

    func testA06_multiSkeletonExportThrows() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton1 = Skeleton(name: "mouse", nodes: [Node(name: "nose")])
        let skeleton2 = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")

        let inst1 = Instance(skeleton: skeleton1, points: PointsArray(count: 1))
        let inst2 = Instance(skeleton: skeleton2, points: PointsArray(count: 1))
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst1, inst2])

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton1, skeleton2],
            tracks: []
        )

        let outputPath = dir.appendingPathComponent("multi_skel.h5").path

        XCTAssertThrowsError(try AnalysisHDF5Codec.write(labels, to: outputPath)) { error in
            guard let sleapError = error as? SleapIOError,
                  case .unsupportedFormat = sleapError else {
                XCTFail("Expected SleapIOError.unsupportedFormat, got \(error)")
                return
            }
        }
    }

    // MARK: - A07: Write preserves tracks and scores

    func testA07_writePreservesTracksAndScores() throws {
        let inputPath = try requireFixture("analysis_h5/analysis_scores.h5")
        let labels = try AnalysisHDF5Codec.read(from: inputPath)

        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let outputPath = dir.appendingPathComponent("roundtrip_scores.h5").path

        try AnalysisHDF5Codec.write(labels, to: outputPath)
        let reloaded = try AnalysisHDF5Codec.read(from: outputPath)

        // Track count and names preserved.
        XCTAssertEqual(reloaded.tracks.count, labels.tracks.count)
        let originalTrackNames = labels.tracks.map(\.name).sorted()
        let reloadedTrackNames = reloaded.tracks.map(\.name).sorted()
        XCTAssertEqual(reloadedTrackNames, originalTrackNames)

        // Scores preserved on first instance of first frame.
        let origInst = labels[0].instances[0] as? PredictedInstance
        let reloadedInst = reloaded[0].instances[0] as? PredictedInstance
        XCTAssertNotNil(origInst)
        XCTAssertNotNil(reloadedInst)
        if let orig = origInst, let rel = reloadedInst {
            XCTAssertEqual(rel.score, orig.score, accuracy: 1e-5)
        }
    }

    // MARK: - A08: Round trip

    func testA08_roundTrip() throws {
        let inputPath = try requireFixture("analysis_h5/analysis_minimal.h5")
        let labels = try AnalysisHDF5Codec.read(from: inputPath)

        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let outputPath = dir.appendingPathComponent("roundtrip.h5").path

        try AnalysisHDF5Codec.write(labels, to: outputPath)
        let reloaded = try AnalysisHDF5Codec.read(from: outputPath)

        XCTAssertEqual(reloaded.frameCount, labels.frameCount)
        XCTAssertEqual(reloaded.tracks.count, labels.tracks.count)
        XCTAssertEqual(reloaded.skeletons[0].nodes.count, labels.skeletons[0].nodes.count)
        XCTAssertEqual(reloaded.skeletons[0].nodes.map(\.name),
                       labels.skeletons[0].nodes.map(\.name))

        // Compare coordinates of first instance in first frame.
        let origPoints = labels[0].instances[0].points
        let reloadedPoints = reloaded[0].instances[0].points
        for i in 0..<origPoints.count {
            XCTAssertEqual(reloadedPoints[i].x, origPoints[i].x, accuracy: 1e-5)
            XCTAssertEqual(reloadedPoints[i].y, origPoints[i].y, accuracy: 1e-5)
        }
    }

    // MARK: - P401: Eager import

    func testP401_importIsEager() throws {
        let path = try requireFixture("analysis_h5/analysis_minimal.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        XCTAssertFalse(labels.isLazy, "Analysis HDF5 import should be eager")
    }

    // MARK: - P408: Missing poses are NaN

    func testP408_missingPosesAreNaN() throws {
        let path = try requireFixture("analysis_h5/analysis_missing_tracks.h5")
        let labels = try AnalysisHDF5Codec.read(from: path)

        // Verify that absent tracks produce no instance (not NaN-filled fakes).
        // Frame 1 should only have track 0. No fake NaN instance for track 1.
        let frame1 = labels[1]
        let track1 = labels.tracks.first { $0.name.contains("1") }
        let track1Instances = frame1.instances.filter { $0.track === track1 }
        XCTAssertTrue(track1Instances.isEmpty,
                      "Absent track should produce no instance, not a NaN-filled one (P408)")
    }

    // MARK: - Regression: multi-video export rejection

    /// P1 regression: Multi-video labels must be rejected, not silently merged.
    func testMultiVideoExportThrows() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton = Skeleton(name: "animal", nodes: [Node(name: "head")])
        let video1 = Video(filename: "video1.mp4")
        let video2 = Video(filename: "video2.mp4")

        let inst1 = Instance(skeleton: skeleton, points: PointsArray(count: 1))
        let inst2 = Instance(skeleton: skeleton, points: PointsArray(count: 1))
        let frame1 = LabeledFrame(video: video1, frameIndex: 0, instances: [inst1])
        let frame2 = LabeledFrame(video: video2, frameIndex: 0, instances: [inst2])

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame1, frame2]),
            videos: [video1, video2],
            skeletons: [skeleton],
            tracks: []
        )

        let outputPath = dir.appendingPathComponent("multi_video.h5").path
        XCTAssertThrowsError(try AnalysisHDF5Codec.write(labels, to: outputPath)) { error in
            guard case SleapIOError.unsupportedFormat = error else {
                XCTFail("Expected unsupportedFormat for multi-video, got \(error)")
                return
            }
        }
    }

    /// P1 regression: Trackless data must round-trip through analysis HDF5.
    func testTracklessDataRoundTrip() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton = Skeleton(name: "DLC", nodes: [
            Node(name: "head"), Node(name: "body"), Node(name: "tail")
        ])
        let video = Video(filename: "test.mp4")

        let points = PointsArray(points: [
            Point(x: 100, y: 200, visible: true, complete: true),
            Point(x: 150, y: 250, visible: true, complete: true),
            Point(x: 200, y: 300, visible: true, complete: true),
        ])
        // No track assignment
        let inst = Instance(skeleton: skeleton, points: points)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst])

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        let outputPath = dir.appendingPathComponent("trackless.h5").path
        try AnalysisHDF5Codec.write(labels, to: outputPath)
        let reloaded = try AnalysisHDF5Codec.read(from: outputPath)

        XCTAssertEqual(reloaded.frameCount, 1, "Trackless data should produce 1 frame after round-trip")
        XCTAssertEqual(reloaded[0].instances.count, 1, "Trackless data should preserve the instance")
        XCTAssertEqual(reloaded[0].instances[0].points[0].x, 100, accuracy: 1e-3)
    }

    // MARK: - Error handling

    func testErrorMalformed() throws {
        let path = try requireFixture("analysis_h5/analysis_malformed.h5")

        XCTAssertThrowsError(try AnalysisHDF5Codec.read(from: path)) { error in
            guard let sleapError = error as? SleapIOError,
                  case .corruptData = sleapError else {
                XCTFail("Expected SleapIOError.corruptData, got \(error)")
                return
            }
        }
    }

    func testErrorFileNotFound() {
        let path = "/nonexistent/path/to/analysis.h5"

        XCTAssertThrowsError(try AnalysisHDF5Codec.read(from: path)) { error in
            guard let sleapError = error as? SleapIOError,
                  case .fileNotFound = sleapError else {
                XCTFail("Expected SleapIOError.fileNotFound, got \(error)")
                return
            }
        }
    }
}
