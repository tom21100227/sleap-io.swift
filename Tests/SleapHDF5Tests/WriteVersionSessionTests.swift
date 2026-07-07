import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// Tests for the write-version migration (#43) and the Python-compatible session
/// schema (#56).
///
/// The version-matrix tests assert that ``SLPWriter/minimumFormatId(for:)``
/// stamps the lowest `format_id` that can represent the data (downgrade-on-save),
/// both directly and through a real write→reopen. The session tests round-trip a
/// ``RecordingSession`` with full calibration (and a synchronized frame group)
/// through save/reload, and confirm the legacy `camera_to_video` schema still
/// loads.
final class WriteVersionSessionTests: XCTestCase {

    // MARK: - Fixtures

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_wvs_\(UUID().uuidString).slp")
    }

    private func makeSkeleton() -> Skeleton {
        Skeleton(name: "fly", nodes: [Node(name: "head"), Node(name: "tail")])
    }

    /// A minimal points-only ``Labels``: one video, one track, one user instance.
    private func makePointsOnlyLabels() -> Labels {
        let skeleton = makeSkeleton()
        let video = Video(filename: "points.mp4")
        let track = Track(name: "track_0")
        let inst = Instance(
            skeleton: skeleton,
            points: PointsArray(points: [
                Point(x: 10, y: 20, visible: true, complete: true),
                Point(x: 30, y: 40, visible: true, complete: true),
            ]),
            track: track
        )
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst])
        return Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )
    }

    /// Read the `format_id` attribute a file was stamped with.
    private func readFormatId(_ url: URL) async throws -> Float {
        let actor = try HDF5FileActor.openReadOnly(path: url.path)
        return try await actor.withFile { file in
            try file.openGroup(name: "metadata").readFloatAttribute(name: "format_id")
        }
    }

    // MARK: - #43: version matrix (direct)

    /// The feature matrix picks the correct minimum `format_id` per feature, and
    /// the highest applicable floor wins when several features are present.
    func testMinimumFormatIdMatrix() {
        // Points-only downgrades to the 1.2 base (tracking_score + center-origin).
        let pointsOnly = makePointsOnlyLabels()
        XCTAssertEqual(SLPWriter.minimumFormatId(for: pointsOnly), 1.2, accuracy: 1e-4)

        // ROIs or masks → 1.5.
        let withMask = makePointsOnlyLabels()
        withMask.masks = [SegmentationMask(rleCounts: [1, 2, 3], height: 4, width: 4, name: "m")]
        XCTAssertEqual(SLPWriter.minimumFormatId(for: withMask), 1.5, accuracy: 1e-4)

        let withROI = makePointsOnlyLabels()
        withROI.rois = [ROI(annotationType: .boundingBox, name: "r",
                            points: [SIMD2<Float>(0, 0), SIMD2<Float>(10, 0),
                                     SIMD2<Float>(10, 10), SIMD2<Float>(0, 10)])]
        XCTAssertEqual(SLPWriter.minimumFormatId(for: withROI), 1.5, accuracy: 1e-4)

        // Bounding boxes or centroids → 1.7.
        let withBbox = makePointsOnlyLabels()
        withBbox.bboxes = [BoundingBox(xCenter: 5, yCenter: 5, width: 2, height: 2)]
        XCTAssertEqual(SLPWriter.minimumFormatId(for: withBbox), 1.7, accuracy: 1e-4)

        let withCentroid = makePointsOnlyLabels()
        withCentroid.centroids = [Centroid(x: 5, y: 5)]
        XCTAssertEqual(SLPWriter.minimumFormatId(for: withCentroid), 1.7, accuracy: 1e-4)

        // Identities → 1.9.
        let withIdentity = makePointsOnlyLabels()
        withIdentity.identities = [Identity(name: "id0")]
        XCTAssertEqual(SLPWriter.minimumFormatId(for: withIdentity), 1.9, accuracy: 1e-4)

        // Highest floor wins: masks (1.5) + bboxes (1.7) + identities (1.9) → 1.9.
        let combined = makePointsOnlyLabels()
        combined.masks = [SegmentationMask(rleCounts: [1], height: 2, width: 2, name: "m")]
        combined.bboxes = [BoundingBox(xCenter: 1, yCenter: 1, width: 1, height: 1)]
        combined.identities = [Identity(name: "id0")]
        XCTAssertEqual(SLPWriter.minimumFormatId(for: combined), 1.9, accuracy: 1e-4)

        // Masks + centroids: centroids (1.7) outranks masks (1.5).
        let masksAndCentroids = makePointsOnlyLabels()
        masksAndCentroids.masks = [SegmentationMask(rleCounts: [1], height: 2, width: 2, name: "m")]
        masksAndCentroids.centroids = [Centroid(x: 1, y: 1)]
        XCTAssertEqual(SLPWriter.minimumFormatId(for: masksAndCentroids), 1.7, accuracy: 1e-4)
    }

    // MARK: - #43: version matrix (write → reopen)

    /// A points-only write is stamped 1.2 on disk, and its data round-trips —
    /// exactly the downgraded output an older SLEAP can open.
    func testPointsOnlyWritesFormat1_2AndRoundTrips() async throws {
        let labels = makePointsOnlyLabels()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await SLPWriter.write(labels, to: url.path)
        let fid = try await readFormatId(url)
        XCTAssertEqual(fid, 1.2, accuracy: 1e-4, "points-only should downgrade to 1.2")
        XCTAssertLessThanOrEqual(fid, 1.4, "downgraded output must stay openable by old SLEAP")

        let reloaded = try await SLPReader.read(from: url.path)
        reloaded.materialize()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.frameStore.frame(at: 0).instances.count, 1)
    }

    /// Masks bump the stamp to exactly 1.5 (the newest Python-native version), not
    /// higher — so real Python SLEAP can still open the file.
    func testMasksWriteFormat1_5() async throws {
        let labels = makePointsOnlyLabels()
        labels.masks = [SegmentationMask(rleCounts: [1, 2], height: 3, width: 3, name: "m")]
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await SLPWriter.write(labels, to: url.path)
        let fmt = try await readFormatId(url)
        XCTAssertEqual(fmt, 1.5, accuracy: 1e-4)
    }

    /// Bounding boxes bump the stamp to 1.7.
    func testBboxesWriteFormat1_7() async throws {
        let labels = makePointsOnlyLabels()
        labels.bboxes = [BoundingBox(xCenter: 5, yCenter: 5, width: 2, height: 2,
                                     videoIndex: 0, frameIndex: 0)]
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await SLPWriter.write(labels, to: url.path)
        let fmt = try await readFormatId(url)
        XCTAssertEqual(fmt, 1.7, accuracy: 1e-4)
    }

    /// Identities bump the stamp to 1.9.
    func testIdentitiesWriteFormat1_9() async throws {
        let labels = makePointsOnlyLabels()
        labels.identities = [Identity(name: "id0", color: "#ff0000")]
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await SLPWriter.write(labels, to: url.path)
        let fmt = try await readFormatId(url)
        XCTAssertEqual(fmt, 1.9, accuracy: 1e-4)
    }

    // MARK: - #56: session round-trip with calibration

    private func makeCalibratedCamera(name: String, seed: Float) -> Camera {
        Camera(
            name: name,
            matrix: [1000 + seed, 0, 640, 0, 1000 + seed, 360, 0, 0, 1],
            distortionCoefficients: [0.1, -0.05, 0.001, 0.002, 0.0].map { Float($0 + Double(seed) / 1000) },
            size: (width: 1280, height: 720),
            rvec: [0.01 + seed, 0.02, 0.03],
            tvec: [1.0, 2.0 + seed, 3.0]
        )
    }

    /// A ``RecordingSession`` with two fully-calibrated cameras mapped to two
    /// videos round-trips through save/reload with intrinsics, extrinsics,
    /// distortion, size, and the camera→video mapping preserved.
    func testSessionCalibrationRoundTrip() async throws {
        let skeleton = makeSkeleton()
        let video0 = Video(filename: "camA.mp4")
        let video1 = Video(filename: "camB.mp4")
        let inst0 = Instance(skeleton: skeleton, points: PointsArray(points: [
            Point(x: 1, y: 2, visible: true, complete: true),
            Point(x: 3, y: 4, visible: true, complete: true),
        ]))
        let inst1 = Instance(skeleton: skeleton, points: PointsArray(points: [
            Point(x: 5, y: 6, visible: true, complete: true),
            Point(x: 7, y: 8, visible: true, complete: true),
        ]))
        let frame0 = LabeledFrame(video: video0, frameIndex: 0, instances: [inst0])
        let frame1 = LabeledFrame(video: video1, frameIndex: 0, instances: [inst1])

        let camA = makeCalibratedCamera(name: "camA", seed: 1)
        let camB = makeCalibratedCamera(name: "camB", seed: 2)
        let session = RecordingSession()
        session.cameraToVideo[camA] = video0
        session.cameraToVideo[camB] = video1

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame0, frame1]),
            videos: [video0, video1],
            skeletons: [skeleton],
            tracks: [],
            sessions: [session]
        )

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SLPWriter.write(labels, to: url.path)

        let reloaded = try await SLPReader.read(from: url.path)
        XCTAssertEqual(reloaded.sessions.count, 1)
        let restored = reloaded.sessions[0]
        XCTAssertEqual(restored.cameraToVideo.count, 2)

        // Index restored cameras by name.
        var camByName: [String: Camera] = [:]
        var videoByCamName: [String: Video] = [:]
        for (cam, video) in restored.cameraToVideo {
            camByName[cam.name] = cam
            videoByCamName[cam.name] = video
        }

        // camA maps to camA.mp4, camB to camB.mp4.
        XCTAssertEqual(videoByCamName["camA"]?.filename, "camA.mp4")
        XCTAssertEqual(videoByCamName["camB"]?.filename, "camB.mp4")

        // Intrinsics / distortion / extrinsics / size round-trip.
        try assertCameraEqual(camByName["camA"], makeCalibratedCamera(name: "camA", seed: 1))
        try assertCameraEqual(camByName["camB"], makeCalibratedCamera(name: "camB", seed: 2))
    }

    private func assertCameraEqual(_ got: Camera?, _ expected: Camera,
                                   file: StaticString = #file, line: UInt = #line) throws {
        let camera = try XCTUnwrap(got, "camera missing", file: file, line: line)
        XCTAssertEqual(camera.name, expected.name, file: file, line: line)
        XCTAssertEqual(camera.size?.width, expected.size?.width, file: file, line: line)
        XCTAssertEqual(camera.size?.height, expected.size?.height, file: file, line: line)
        assertFloatArrayEqual(camera.matrix, expected.matrix, file: file, line: line)
        assertFloatArrayEqual(camera.distortionCoefficients, expected.distortionCoefficients,
                              file: file, line: line)
        assertFloatArrayEqual(camera.rvec, expected.rvec, file: file, line: line)
        assertFloatArrayEqual(camera.tvec, expected.tvec, file: file, line: line)
    }

    private func assertFloatArrayEqual(_ got: [Float]?, _ expected: [Float]?,
                                       file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(got?.count, expected?.count, "array length mismatch", file: file, line: line)
        guard let got = got, let expected = expected, got.count == expected.count else { return }
        for i in 0..<got.count {
            XCTAssertEqual(got[i], expected[i], accuracy: 1e-4, file: file, line: line)
        }
    }

    /// A session with no calibration on its cameras still round-trips the
    /// camera→video mapping (names + mapping survive; intrinsics remain nil).
    func testSessionWithoutCalibrationRoundTrip() async throws {
        let skeleton = makeSkeleton()
        let video0 = Video(filename: "left.mp4")
        let frame0 = LabeledFrame(video: video0, frameIndex: 0, instances: [
            Instance(skeleton: skeleton, points: PointsArray(points: [
                Point(x: 1, y: 1, visible: true, complete: true),
                Point(x: 2, y: 2, visible: true, complete: true),
            ]))
        ])
        let session = RecordingSession()
        session.cameraToVideo[Camera(name: "left")] = video0

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame0]),
            videos: [video0],
            skeletons: [skeleton],
            tracks: [],
            sessions: [session]
        )

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SLPWriter.write(labels, to: url.path)

        let reloaded = try await SLPReader.read(from: url.path)
        XCTAssertEqual(reloaded.sessions.count, 1)
        let restored = reloaded.sessions[0]
        XCTAssertEqual(restored.cameraToVideo.count, 1)
        let (cam, video) = try XCTUnwrap(restored.cameraToVideo.first)
        XCTAssertEqual(cam.name, "left")
        XCTAssertEqual(video.filename, "left.mp4")
        XCTAssertNil(cam.matrix)
        XCTAssertNil(cam.rvec)
    }

    /// A synchronized ``FrameGroup`` (with an ``InstanceGroup`` linking one
    /// instance per camera) round-trips through save/reload, with the reloaded
    /// instances resolving to the corresponding reloaded frames.
    func testFrameGroupRoundTrip() async throws {
        let skeleton = makeSkeleton()
        let video0 = Video(filename: "camA.mp4")
        let video1 = Video(filename: "camB.mp4")
        let inst0 = Instance(skeleton: skeleton, points: PointsArray(points: [
            Point(x: 1, y: 2, visible: true, complete: true),
            Point(x: 3, y: 4, visible: true, complete: true),
        ]))
        let inst1 = Instance(skeleton: skeleton, points: PointsArray(points: [
            Point(x: 5, y: 6, visible: true, complete: true),
            Point(x: 7, y: 8, visible: true, complete: true),
        ]))
        let frame0 = LabeledFrame(video: video0, frameIndex: 0, instances: [inst0])
        let frame1 = LabeledFrame(video: video1, frameIndex: 0, instances: [inst1])

        let camA = makeCalibratedCamera(name: "camA", seed: 1)
        let camB = makeCalibratedCamera(name: "camB", seed: 2)

        let session = RecordingSession()
        session.cameraToVideo[camA] = video0
        session.cameraToVideo[camB] = video1

        let frameGroup = FrameGroup()
        frameGroup.frames[camA] = frame0
        frameGroup.frames[camB] = frame1
        let instanceGroup = InstanceGroup()
        instanceGroup.instances[camA] = inst0
        instanceGroup.instances[camB] = inst1
        frameGroup.instanceGroups = [instanceGroup]
        session.frameGroups = [frameGroup]

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame0, frame1]),
            videos: [video0, video1],
            skeletons: [skeleton],
            tracks: [],
            sessions: [session]
        )

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SLPWriter.write(labels, to: url.path)

        let reloaded = try await SLPReader.read(from: url.path)
        let restored = try XCTUnwrap(reloaded.sessions.first)
        XCTAssertEqual(restored.frameGroups.count, 1)
        let restoredGroup = restored.frameGroups[0]
        XCTAssertEqual(restoredGroup.instanceGroups.count, 1)
        let restoredInstanceGroup = restoredGroup.instanceGroups[0]
        XCTAssertEqual(restoredInstanceGroup.instances.count, 2)

        // Instances resolve (by identity) to the reloaded frames' instances.
        let reloadedFrame0Inst0 = reloaded.frameStore.frame(at: 0).instances[0]
        let reloadedFrame1Inst0 = reloaded.frameStore.frame(at: 1).instances[0]
        var instByCamName: [String: Instance] = [:]
        var frameByCamName: [String: LabeledFrame] = [:]
        for (cam, inst) in restoredInstanceGroup.instances { instByCamName[cam.name] = inst }
        for (cam, frame) in restoredGroup.frames { frameByCamName[cam.name] = frame }

        XCTAssertTrue(instByCamName["camA"] === reloadedFrame0Inst0)
        XCTAssertTrue(instByCamName["camB"] === reloadedFrame1Inst0)
        XCTAssertTrue(frameByCamName["camA"] === reloaded.frameStore.frame(at: 0))
        XCTAssertTrue(frameByCamName["camB"] === reloaded.frameStore.frame(at: 1))
    }

    // MARK: - #56: SessionSchema unit coverage

    /// A camera survives ``SessionSchema/cameraDict(_:)`` →
    /// ``SessionSchema/makeCamera(from:)``.
    func testCameraDictRoundTrip() {
        let camera = makeCalibratedCamera(name: "back", seed: 3)
        let dict = SessionSchema.cameraDict(camera)
        let restored = SessionSchema.makeCamera(from: dict)

        XCTAssertEqual(restored.name, "back")
        XCTAssertEqual(restored.size?.width, 1280)
        XCTAssertEqual(restored.size?.height, 720)
        assertFloatArrayEqual(restored.matrix, camera.matrix)
        assertFloatArrayEqual(restored.distortionCoefficients, camera.distortionCoefficients)
        assertFloatArrayEqual(restored.rvec, camera.rvec)
        assertFloatArrayEqual(restored.tvec, camera.tvec)

        // The matrix is emitted as Python's nested 3x3 list.
        XCTAssertNotNil(dict["matrix"] as? [[Any]], "matrix should serialize as a nested 3x3 list")
    }

    /// The legacy `camera_to_video` schema still deserializes into
    /// `cameraToVideo`, preserving back-compat with old-schema session files.
    func testLegacySchemaBackCompatRead() {
        let video0 = Video(filename: "v0.mp4")
        let video1 = Video(filename: "v1.mp4")
        let legacyDict: [String: Any] = [
            "camera_to_video": [
                ["camera_name": "cam0", "video_idx": 0],
                ["camera_name": "cam1", "video_idx": 1],
            ]
        ]

        let session = SessionSchema.makeSession(
            from: legacyDict,
            videos: [video0, video1],
            videoIdMap: [:],
            frames: []
        )

        XCTAssertEqual(session.cameraToVideo.count, 2)
        var videoByCamName: [String: Video] = [:]
        for (cam, video) in session.cameraToVideo { videoByCamName[cam.name] = video }
        XCTAssertEqual(videoByCamName["cam0"]?.filename, "v0.mp4")
        XCTAssertEqual(videoByCamName["cam1"]?.filename, "v1.mp4")
    }

    /// The written session dictionary carries both the modern keys and the legacy
    /// `camera_to_video` array (so old-schema readers keep working).
    func testSessionDictEmitsModernAndLegacyKeys() {
        let video0 = Video(filename: "v0.mp4")
        let camA = makeCalibratedCamera(name: "camA", seed: 1)
        let session = RecordingSession()
        session.cameraToVideo[camA] = video0

        let ordered = SessionSchema.orderedCameras(for: session)
        let dict = SessionSchema.sessionDict(
            session,
            orderedCameras: ordered,
            videoIndexMap: [ObjectIdentifier(video0): 0],
            labeledFrameToIdx: [:],
            instanceToLfInst: [:]
        )

        XCTAssertNotNil(dict["calibration"] as? [String: Any])
        let map = dict["camcorder_to_video_idx_map"] as? [String: Any]
        XCTAssertEqual(map?["0"] as? Int, 0)
        let legacy = dict["camera_to_video"] as? [[String: Any]]
        XCTAssertEqual(legacy?.count, 1)
        XCTAssertEqual(legacy?.first?["camera_name"] as? String, "camA")
    }
}
