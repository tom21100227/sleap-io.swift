import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// Issue #58: `frame_group_dicts` serialization/deserialization through
/// ``SessionSchema``.
///
/// Exercises the pure model↔dictionary translation (no HDF5 I/O) end to end,
/// including a JSON round-trip via `JSONSerialization` to mirror what
/// ``SLPWriter``/``SLPReader`` do on disk, and confirms the additive
/// triangulated ``Instance3D`` `points` survive.
final class FrameGroupSerializationTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSkeleton() -> Skeleton {
        Skeleton(name: "fly", nodes: [Node(name: "head"), Node(name: "tail")])
    }

    private func makeCalibratedCamera(name: String, seed: Float) -> Camera {
        Camera(
            name: name,
            matrix: [1000 + seed, 0, 640, 0, 1000 + seed, 360, 0, 0, 1],
            distortionCoefficients: [0.1, -0.05, 0.001, 0.002, 0.0],
            size: (width: 1280, height: 720),
            rvec: [0.01 + seed, 0.02, 0.03],
            tvec: [1.0, 2.0 + seed, 3.0])
    }

    /// A self-contained two-camera session with one synchronized frame group.
    ///
    /// Returns the session plus the index maps a real writer would build so the
    /// test can drive ``SessionSchema/sessionDict(_:orderedCameras:videoIndexMap:labeledFrameToIdx:instanceToLfInst:)``
    /// directly.
    private func makeSessionFixture() -> (
        session: RecordingSession,
        videos: [Video],
        frames: [LabeledFrame],
        videoIndexMap: [ObjectIdentifier: Int],
        labeledFrameToIdx: [ObjectIdentifier: Int],
        instanceToLfInst: [ObjectIdentifier: (Int, Int)]
    ) {
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

        let group = InstanceGroup(instances: [camA: inst0, camB: inst1])
        let frameGroup = FrameGroup(
            frames: [camA: frame0, camB: frame1], instanceGroups: [group])
        let session = RecordingSession(
            cameraToVideo: [camA: video0, camB: video1], frameGroups: [frameGroup])

        return (
            session,
            [video0, video1],
            [frame0, frame1],
            [ObjectIdentifier(video0): 0, ObjectIdentifier(video1): 1],
            [ObjectIdentifier(frame0): 0, ObjectIdentifier(frame1): 1],
            [ObjectIdentifier(inst0): (0, 0), ObjectIdentifier(inst1): (1, 0)])
    }

    /// Serialize `dict` through `JSONSerialization` and back, mirroring the SLP
    /// metadata JSON path (and asserting the payload is JSON-legal).
    private func jsonRoundTrip(_ dict: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Tests

    func testFrameGroupDictsRoundTrip() throws {
        let fixture = makeSessionFixture()

        let ordered = SessionSchema.orderedCameras(for: fixture.session)
        XCTAssertEqual(ordered.map(\.name), ["camA", "camB"])

        let dict = SessionSchema.sessionDict(
            fixture.session,
            orderedCameras: ordered,
            videoIndexMap: fixture.videoIndexMap,
            labeledFrameToIdx: fixture.labeledFrameToIdx,
            instanceToLfInst: fixture.instanceToLfInst)

        // The frame_group_dicts key is present and structurally sound.
        let frameGroupDicts = try XCTUnwrap(dict["frame_group_dicts"] as? [[String: Any]])
        XCTAssertEqual(frameGroupDicts.count, 1)
        let instanceGroups = try XCTUnwrap(
            frameGroupDicts[0]["instance_groups"] as? [[String: Any]])
        XCTAssertEqual(instanceGroups.count, 1)
        let map = try XCTUnwrap(
            instanceGroups[0]["camcorder_to_lf_and_inst_idx_map"] as? [String: Any])
        XCTAssertEqual(map.count, 2)

        // Round-trip through JSON, then decode back into a session.
        let decoded = try jsonRoundTrip(dict)
        let restored = SessionSchema.makeSession(
            from: decoded,
            videos: fixture.videos,
            videoIdMap: [:],
            frames: fixture.frames)

        // Camera -> video map preserved.
        XCTAssertEqual(restored.cameraToVideo.count, 2)
        var videoByCam: [String: String] = [:]
        for (cam, video) in restored.cameraToVideo { videoByCam[cam.name] = video.filename }
        XCTAssertEqual(videoByCam["camA"], "camA.mp4")
        XCTAssertEqual(videoByCam["camB"], "camB.mp4")

        // Frame group + instance group restored; instances resolve (by identity)
        // to the very frames passed in.
        XCTAssertEqual(restored.frameGroups.count, 1)
        let restoredGroup = restored.frameGroups[0]
        XCTAssertEqual(restoredGroup.instanceGroups.count, 1)
        let restoredInstanceGroup = restoredGroup.instanceGroups[0]
        XCTAssertEqual(restoredInstanceGroup.instances.count, 2)

        var instByCam: [String: Instance] = [:]
        for (cam, inst) in restoredInstanceGroup.instances { instByCam[cam.name] = inst }
        XCTAssertTrue(instByCam["camA"] === fixture.frames[0].instances[0])
        XCTAssertTrue(instByCam["camB"] === fixture.frames[1].instances[0])

        // No Instance3D was set -> the additive `points` key is absent and the
        // restored group has no 3D pose.
        XCTAssertNil(instanceGroups[0]["points"])
        XCTAssertNil(restoredInstanceGroup.instance3D)
    }

    func testInstance3DPointsRoundTrip() throws {
        let fixture = makeSessionFixture()
        let skeleton = fixture.frames[0].instances[0].skeleton

        // Attach a triangulated 3D pose with one visible and one missing node.
        let group = fixture.session.frameGroups[0].instanceGroups[0]
        group.instance3D = Instance3D(
            skeleton: skeleton,
            points: [
                Point3D(x: 1.5, y: -2.5, z: 3.5, visible: true),
                .missing,
            ],
            score: 0.87)

        let ordered = SessionSchema.orderedCameras(for: fixture.session)
        let dict = SessionSchema.sessionDict(
            fixture.session,
            orderedCameras: ordered,
            videoIndexMap: fixture.videoIndexMap,
            labeledFrameToIdx: fixture.labeledFrameToIdx,
            instanceToLfInst: fixture.instanceToLfInst)

        let decoded = try jsonRoundTrip(dict)
        let restored = SessionSchema.makeSession(
            from: decoded,
            videos: fixture.videos,
            videoIdMap: [:],
            frames: fixture.frames)

        let restoredGroup = try XCTUnwrap(restored.frameGroups.first?.instanceGroups.first)
        let instance3D = try XCTUnwrap(restoredGroup.instance3D)
        XCTAssertEqual(instance3D.points.count, 2)
        XCTAssertTrue(instance3D.points[0].visible)
        XCTAssertEqual(instance3D.points[0].x, 1.5, accuracy: 1e-5)
        XCTAssertEqual(instance3D.points[0].y, -2.5, accuracy: 1e-5)
        XCTAssertEqual(instance3D.points[0].z, 3.5, accuracy: 1e-5)
        XCTAssertFalse(instance3D.points[1].visible)
        XCTAssertTrue(instance3D.points[1].x.isNaN)
        XCTAssertEqual(instance3D.score ?? .nan, 0.87, accuracy: 1e-5)
        // The 3D pose is wired to the (reloaded) 2D instances' skeleton.
        XCTAssertTrue(instance3D.skeleton === skeleton)
    }

    func testTriangulatedInstance3DRoundTrip() throws {
        // End-to-end: triangulate real projected observations, then serialize and
        // recover the 3D pose through SessionSchema.
        let fixture = makeSessionFixture()
        let group = fixture.session.frameGroups[0].instanceGroups[0]
        let triangulated = try XCTUnwrap(group.triangulate())
        XCTAssertGreaterThan(triangulated.nVisible, 0)

        let ordered = SessionSchema.orderedCameras(for: fixture.session)
        let dict = SessionSchema.sessionDict(
            fixture.session,
            orderedCameras: ordered,
            videoIndexMap: fixture.videoIndexMap,
            labeledFrameToIdx: fixture.labeledFrameToIdx,
            instanceToLfInst: fixture.instanceToLfInst)

        let decoded = try jsonRoundTrip(dict)
        let restored = SessionSchema.makeSession(
            from: decoded, videos: fixture.videos, videoIdMap: [:], frames: fixture.frames)

        let restored3D = try XCTUnwrap(
            restored.frameGroups.first?.instanceGroups.first?.instance3D)
        XCTAssertEqual(restored3D.points.count, triangulated.points.count)
        for i in 0..<triangulated.points.count where triangulated.points[i].visible {
            XCTAssertEqual(restored3D.points[i].x, triangulated.points[i].x, accuracy: 1e-4)
            XCTAssertEqual(restored3D.points[i].y, triangulated.points[i].y, accuracy: 1e-4)
            XCTAssertEqual(restored3D.points[i].z, triangulated.points[i].z, accuracy: 1e-4)
        }
    }
}
