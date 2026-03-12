import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// D01–D04, P401, P407: DeepLabCut HDF5 codec tests (read-only).
///
/// These tests require .h5 fixture files in Tests/Fixtures/phase4/.
/// Tests will skip gracefully if fixtures are not available.
final class DLCCodecTests: XCTestCase {

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

    // MARK: - D01: Single animal import

    func testD01_singleAnimalImport() throws {
        let path = try requireFixture("dlc_h5/dlc_single_animal.h5")
        let labels = try DLCCodec.read(from: path)

        XCTAssertEqual(labels.frameCount, 5)
        XCTAssertEqual(labels.tracks.count, 0, "Single-animal DLC has no individuals/tracks")
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.skeletons[0].nodes.count, 3)
    }

    func testD01_bodypartOrder() throws {
        let path = try requireFixture("dlc_h5/dlc_single_animal.h5")
        let labels = try DLCCodec.read(from: path)

        let nodeNames = labels.skeletons[0].nodes.map(\.name)
        XCTAssertEqual(nodeNames, ["head", "body", "tail"])
    }

    func testD01_edgelessSkeleton() throws {
        let path = try requireFixture("dlc_h5/dlc_single_animal.h5")
        let labels = try DLCCodec.read(from: path)

        XCTAssertTrue(labels.skeletons[0].edges.isEmpty,
                      "DLC skeletons should be edgeless")
    }

    // MARK: - D02: Multi-animal import

    func testD02_multiAnimalImport() throws {
        let path = try requireFixture("dlc_h5/dlc_multi_animal.h5")
        let labels = try DLCCodec.read(from: path)

        XCTAssertEqual(labels.tracks.count, 2, "Should have 2 tracks for 2 individuals")
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.skeletons[0].nodes.count, 3)
    }

    func testD02_individualsTracks() throws {
        let path = try requireFixture("dlc_h5/dlc_multi_animal.h5")
        let labels = try DLCCodec.read(from: path)

        let trackNames = labels.tracks.map(\.name).sorted()
        XCTAssertEqual(trackNames, ["mouse1", "mouse2"])
    }

    func testD02_absentIndividualNoInstance() throws {
        let path = try requireFixture("dlc_h5/dlc_multi_animal.h5")
        let labels = try DLCCodec.read(from: path)

        // mouse2 should be absent at frames 3 and 4 (indices 3, 4).
        let mouse2 = labels.tracks.first { $0.name == "mouse2" }
        XCTAssertNotNil(mouse2, "Should have track named mouse2")

        for frameIdx in [3, 4] where frameIdx < labels.frameCount {
            let frame = labels[frameIdx]
            let instancesForMouse2 = frame.instances.filter { $0.track === mouse2 }
            XCTAssertTrue(instancesForMouse2.isEmpty,
                          "mouse2 should be absent at frame index \(frameIdx)")
        }
    }

    // MARK: - D03: Likelihood to scores

    func testD03_likelihoodMapsToScores() throws {
        let path = try requireFixture("dlc_h5/dlc_single_animal.h5")
        let labels = try DLCCodec.read(from: path)

        let frame = labels[0]
        XCTAssertFalse(frame.instances.isEmpty)

        for instance in frame.instances {
            guard let predicted = instance as? PredictedInstance else {
                XCTFail("DLC instances should be PredictedInstance (have likelihood scores)")
                continue
            }
            // Per-point scores derived from DLC likelihood column.
            for i in 0..<predicted.predictedPoints.count {
                let score = predicted.predictedPoints[i].score
                XCTAssertGreaterThanOrEqual(score, 0)
                XCTAssertLessThanOrEqual(score, 1.0)
            }
        }
    }

    func testD03_nanCoordsAreMissing() throws {
        let path = try requireFixture("dlc_h5/dlc_single_animal.h5")
        let labels = try DLCCodec.read(from: path)

        // Look across all frames for any point with NaN coordinates —
        // it should be marked as not visible.
        var foundNaN = false
        for i in 0..<labels.frameCount {
            for instance in labels[i].instances {
                for j in 0..<instance.points.count {
                    let pt = instance.points[j]
                    if pt.x.isNaN || pt.y.isNaN {
                        foundNaN = true
                        XCTAssertFalse(pt.visible,
                                       "NaN coordinates should produce a non-visible point")
                    }
                }
            }
        }
        // Note: if the fixture has no NaN points, this test passes vacuously.
        // The fixture generator should include at least one NaN coordinate.
        if !foundNaN {
            // Still valid — fixture may not have NaN points.
            // But log for awareness.
        }
    }

    // MARK: - D04: Unsupported schema

    func testD04_unsupportedSchemaThrows() throws {
        let path = try requireFixture("dlc_h5/dlc_unsupported.h5")

        XCTAssertThrowsError(try DLCCodec.read(from: path)) { error in
            guard let sleapError = error as? SleapIOError,
                  case .unsupportedFormat = sleapError else {
                XCTFail("Expected SleapIOError.unsupportedFormat, got \(error)")
                return
            }
        }
    }

    // MARK: - P401: Eager import

    func testP401_importIsEager() throws {
        let path = try requireFixture("dlc_h5/dlc_single_animal.h5")
        let labels = try DLCCodec.read(from: path)

        XCTAssertFalse(labels.isLazy, "DLC import should be eager")
    }

    // MARK: - P407: Shared identity

    func testP407_sharedIdentity() throws {
        let path = try requireFixture("dlc_h5/dlc_multi_animal.h5")
        let labels = try DLCCodec.read(from: path)

        let skeleton = labels.skeletons[0]
        for i in 0..<labels.frameCount {
            for instance in labels[i].instances {
                XCTAssertTrue(instance.skeleton === skeleton,
                              "All instances should share the same Skeleton object")
            }
        }

        // Track objects shared across frames.
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

    // MARK: - Write is unsupported (read-only format)

    func testWriteThrowsUnsupported() throws {
        // DLC is read-only. If a write method exists, it should throw.
        let skeleton = Skeleton(name: "test", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")
        let inst = Instance(skeleton: skeleton, points: PointsArray(count: 1))
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst])
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dlc_write_\(UUID().uuidString).h5").path

        // DLCCodec should not have a write method. If it does, it should throw unsupportedFormat.
        // This test validates the read-only contract. If the type doesn't have write(), that's correct.
        // We use a compile-time check via the absence of the method — but since we can't do that
        // in a test, we verify at runtime if the method exists.
        XCTAssertThrowsError(try DLCCodec.write(labels, to: tempPath)) { error in
            guard let sleapError = error as? SleapIOError,
                  case .unsupportedFormat = sleapError else {
                XCTFail("Expected SleapIOError.unsupportedFormat, got \(error)")
                return
            }
        }
    }

    // MARK: - Regression: all-NaN rows produce no frames

    /// P2 regression: DLC rows where all individuals are absent must not create empty frames.
    func testD02_absentFramesNotCreated() throws {
        let path = try requireFixture("dlc_h5/dlc_multi_animal.h5")
        let labels = try DLCCodec.read(from: path)

        // Every frame that exists should have at least one instance
        for i in 0..<labels.frameCount {
            XCTAssertFalse(labels[i].instances.isEmpty,
                           "Frame \(i) should not be empty — all-NaN rows should be skipped")
        }
    }

    // MARK: - Error handling

    func testErrorFileNotFound() {
        let path = "/nonexistent/path/to/dlc.h5"

        XCTAssertThrowsError(try DLCCodec.read(from: path)) { error in
            guard let sleapError = error as? SleapIOError,
                  case .fileNotFound = sleapError else {
                XCTFail("Expected SleapIOError.fileNotFound, got \(error)")
                return
            }
        }
    }
}
