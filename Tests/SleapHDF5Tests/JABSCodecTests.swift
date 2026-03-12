import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// J01–J05, P401, P407: JABS HDF5 codec tests.
///
/// These tests require .h5 fixture files in Tests/Fixtures/phase4/.
/// Tests will skip gracefully if fixtures are not available.
final class JABSCodecTests: XCTestCase {

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
            .appendingPathComponent("sleap_jabs_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - J01: Single animal import

    func testJ01_singleAnimalImport() throws {
        let path = try requireFixture("jabs_h5/jabs_single_animal.h5")
        let labels = try JABSCodec.read(from: path, config: JABSCodec.Config())

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.frameCount, 5)
        XCTAssertEqual(labels.tracks.count, 1)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.skeletons[0].nodes.count, 4)
    }

    func testJ01_nodeNamesFromFile() throws {
        let path = try requireFixture("jabs_h5/jabs_single_animal.h5")
        let labels = try JABSCodec.read(from: path, config: JABSCodec.Config())

        let nodeNames = labels.skeletons[0].nodes.map(\.name)
        XCTAssertEqual(nodeNames, ["nose", "left_ear", "right_ear", "tail_base"])
    }

    func testJ01_requiresConfigWithoutNodeNames() throws {
        let path = try requireFixture("jabs_h5/jabs_no_node_names.h5")

        // Reading without explicit node names when the file lacks them should throw.
        XCTAssertThrowsError(try JABSCodec.read(from: path, config: JABSCodec.Config())) { error in
            guard let sleapError = error as? SleapIOError,
                  case .invalidSkeleton = sleapError else {
                XCTFail("Expected SleapIOError.invalidSkeleton, got \(error)")
                return
            }
        }
    }

    func testJ01_configNodeNamesOverride() throws {
        let path = try requireFixture("jabs_h5/jabs_no_node_names.h5")

        let config = JABSCodec.Config(nodeNames: ["node_0", "node_1", "node_2"])
        let labels = try JABSCodec.read(from: path, config: config)

        XCTAssertEqual(labels.skeletons[0].nodes.count, 3)
        XCTAssertEqual(labels.skeletons[0].nodes.map(\.name),
                       ["node_0", "node_1", "node_2"])
    }

    // MARK: - J02: Multi-animal identity tracks

    func testJ02_multiAnimalIdentityTracks() throws {
        let path = try requireFixture("jabs_h5/jabs_multi_animal.h5")
        let labels = try JABSCodec.read(from: path, config: JABSCodec.Config())

        XCTAssertEqual(labels.tracks.count, 3)

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

    func testJ02_animalAbsenceNoInstance() throws {
        let path = try requireFixture("jabs_h5/jabs_multi_animal.h5")
        let labels = try JABSCodec.read(from: path, config: JABSCodec.Config())

        // Animal 2 (third track) should be absent at frames 1 and 3.
        guard labels.tracks.count >= 3 else {
            XCTFail("Expected at least 3 tracks")
            return
        }
        let track2 = labels.tracks[2]

        for frameIdx in [1, 3] where frameIdx < labels.frameCount {
            let frame = labels[frameIdx]
            let instancesForTrack2 = frame.instances.filter { $0.track === track2 }
            XCTAssertTrue(instancesForTrack2.isEmpty,
                          "Animal 2 should be absent at frame index \(frameIdx)")
        }
    }

    // MARK: - J03: One instance per identity per frame

    func testJ03_oneInstancePerIdentityPerFrame() throws {
        let path = try requireFixture("jabs_h5/jabs_multi_animal.h5")
        let labels = try JABSCodec.read(from: path, config: JABSCodec.Config())

        for i in 0..<labels.frameCount {
            let frame = labels[i]
            var seenTracks = Set<ObjectIdentifier>()
            for instance in frame.instances {
                if let track = instance.track {
                    let id = ObjectIdentifier(track)
                    XCTAssertFalse(seenTracks.contains(id),
                                   "Frame \(i) has duplicate instance for track '\(track.name)'")
                    seenTracks.insert(id)
                }
            }
        }
    }

    // MARK: - J04: Single-skeleton export only

    func testJ04_singleSkeletonExportOnly() throws {
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

        XCTAssertThrowsError(
            try JABSCodec.write(labels, to: outputPath, config: JABSCodec.Config())
        ) { error in
            guard let sleapError = error as? SleapIOError,
                  case .unsupportedFormat = sleapError else {
                XCTFail("Expected SleapIOError.unsupportedFormat, got \(error)")
                return
            }
        }
    }

    func testJ04_deterministicOutput() throws {
        let inputPath = try requireFixture("jabs_h5/jabs_single_animal.h5")
        let labels = try JABSCodec.read(from: inputPath, config: JABSCodec.Config())

        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let outputPath = dir.appendingPathComponent("deterministic.h5").path

        try JABSCodec.write(labels, to: outputPath, config: JABSCodec.Config())
        let reloaded = try JABSCodec.read(from: outputPath, config: JABSCodec.Config())

        XCTAssertEqual(reloaded.frameCount, labels.frameCount)
        XCTAssertEqual(reloaded.tracks.count, labels.tracks.count)
        XCTAssertEqual(reloaded.skeletons[0].nodes.map(\.name),
                       labels.skeletons[0].nodes.map(\.name))
    }

    // MARK: - J05: Round trip

    func testJ05_roundTrip() throws {
        let inputPath = try requireFixture("jabs_h5/jabs_single_animal.h5")
        let labels = try JABSCodec.read(from: inputPath, config: JABSCodec.Config())

        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let outputPath = dir.appendingPathComponent("roundtrip.h5").path

        try JABSCodec.write(labels, to: outputPath, config: JABSCodec.Config())
        let reloaded = try JABSCodec.read(from: outputPath, config: JABSCodec.Config())

        XCTAssertEqual(reloaded.frameCount, labels.frameCount)
        XCTAssertEqual(reloaded.tracks.count, labels.tracks.count)
        XCTAssertEqual(reloaded.videos.count, labels.videos.count)

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
        let path = try requireFixture("jabs_h5/jabs_single_animal.h5")
        let labels = try JABSCodec.read(from: path, config: JABSCodec.Config())

        XCTAssertFalse(labels.isLazy, "JABS import should be eager")
    }

    // MARK: - P407: Shared identity

    func testP407_sharedIdentity() throws {
        let path = try requireFixture("jabs_h5/jabs_multi_animal.h5")
        let labels = try JABSCodec.read(from: path, config: JABSCodec.Config())

        let skeleton = labels.skeletons[0]
        for i in 0..<labels.frameCount {
            for instance in labels[i].instances {
                XCTAssertTrue(instance.skeleton === skeleton,
                              "All instances should share the same Skeleton object")
            }
        }
    }

    // MARK: - Regression: untracked multi-instance rejection

    /// P2 regression: JABS export must reject untracked multi-instance frames.
    func testUntrackedMultiInstanceExportThrows() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let skeleton = Skeleton(name: "mouse", nodes: [
            Node(name: "nose"), Node(name: "tail")
        ])
        let video = Video(filename: "test.mp4")

        // Two untracked instances in one frame
        let inst1 = Instance(skeleton: skeleton, points: PointsArray(count: 2))
        let inst2 = Instance(skeleton: skeleton, points: PointsArray(count: 2))
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst1, inst2])

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        let outputPath = dir.appendingPathComponent("untracked_multi.h5").path
        XCTAssertThrowsError(
            try JABSCodec.write(labels, to: outputPath, config: JABSCodec.Config())
        ) { error in
            guard case SleapIOError.unsupportedFormat = error else {
                XCTFail("Expected unsupportedFormat for untracked multi-instance, got \(error)")
                return
            }
        }
    }

    // MARK: - Error handling

    func testErrorMalformed() throws {
        let path = try requireFixture("jabs_h5/jabs_malformed.h5")

        XCTAssertThrowsError(
            try JABSCodec.read(from: path, config: JABSCodec.Config())
        ) { error in
            guard let sleapError = error as? SleapIOError,
                  case .corruptData = sleapError else {
                XCTFail("Expected SleapIOError.corruptData, got \(error)")
                return
            }
        }
    }

    func testErrorFileNotFound() {
        let path = "/nonexistent/path/to/jabs.h5"

        XCTAssertThrowsError(
            try JABSCodec.read(from: path, config: JABSCodec.Config())
        ) { error in
            guard let sleapError = error as? SleapIOError,
                  case .fileNotFound = sleapError else {
                XCTFail("Expected SleapIOError.fileNotFound, got \(error)")
                return
            }
        }
    }
}
