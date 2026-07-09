import XCTest
import simd
@testable import SleapIO

/// Issue #58: `FrameGroup` / `InstanceGroup` / `Instance3D` aggregation and
/// multi-view triangulation.
///
/// Covers the pinhole projection math, linear (DLT) triangulation recovering a
/// known 3D point from two and three synthetic cameras, the `Instance3D` model,
/// and construction/aggregation of `FrameGroup` / `InstanceGroup` /
/// `RecordingSession`.
final class FrameGroupTests: XCTestCase {

    // MARK: - Helpers

    /// A pinhole camera with a shared intrinsic matrix and the given pose.
    private func makeCamera(
        name: String, rvec: [Float], tvec: [Float],
        fx: Float = 1000, fy: Float = 1000, cx: Float = 640, cy: Float = 360
    ) -> Camera {
        Camera(
            name: name,
            matrix: [fx, 0, cx, 0, fy, cy, 0, 0, 1],
            size: (width: 1280, height: 720),
            rvec: rvec,
            tvec: tvec)
    }

    /// Three well-separated calibrated cameras looking at a common region.
    private func makeThreeCameras() -> [Camera] {
        [
            makeCamera(name: "cam0", rvec: [0, 0, 0], tvec: [0, 0, 0]),
            makeCamera(name: "cam1", rvec: [0, 0.3, 0], tvec: [-2, 0, 1]),
            makeCamera(name: "cam2", rvec: [0.1, -0.2, 0.05], tvec: [1, 1, 0.5]),
        ]
    }

    private func assertClose(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-2,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, "z", file: file, line: line)
    }

    // MARK: - Projection matrix

    func testProjectionMatrixRequiresFullCalibration() {
        // Missing extrinsics -> no projection matrix.
        let uncalibrated = Camera(name: "c", matrix: [1000, 0, 640, 0, 1000, 360, 0, 0, 1])
        XCTAssertNil(Triangulation.projectionMatrix(for: uncalibrated))

        // Missing intrinsics -> no projection matrix.
        let noIntrinsics = Camera(name: "c", rvec: [0, 0, 0], tvec: [0, 0, 1])
        XCTAssertNil(Triangulation.projectionMatrix(for: noIntrinsics))

        let full = makeCamera(name: "c", rvec: [0, 0, 0], tvec: [0, 0, 0])
        let p = Triangulation.projectionMatrix(for: full)
        XCTAssertEqual(p?.count, 12)
    }

    func testProjectionMatrixIdentityPose() throws {
        // With R = I and t = 0, P = K padded with a zero column, so a point at
        // (X, Y, Z) projects to (fx*X/Z + cx, fy*Y/Z + cy).
        let camera = makeCamera(name: "c", rvec: [0, 0, 0], tvec: [0, 0, 0])
        let actual = try XCTUnwrap(Triangulation.project(SIMD3(0.5, -0.3, 5.0), with: camera))
        let expected = SIMD2<Float>(1000 * 0.5 / 5.0 + 640, 1000 * -0.3 / 5.0 + 360)
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-3)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-3)
    }

    // MARK: - Triangulation

    func testTriangulateRecoversPointFromTwoViews() throws {
        let cameras = Array(makeThreeCameras().prefix(2))
        let world = SIMD3<Float>(0.42, -0.75, 6.0)

        var observations: [(projection: [Double], point: SIMD2<Float>)] = []
        for camera in cameras {
            let projection = try XCTUnwrap(Triangulation.projectionMatrix(for: camera))
            let pixel = try XCTUnwrap(Triangulation.project(world, using: projection))
            observations.append((projection, pixel))
        }

        let recovered = try XCTUnwrap(Triangulation.triangulate(observations: observations))
        assertClose(recovered, world)
    }

    func testTriangulateRecoversPointFromThreeViews() throws {
        let cameras = makeThreeCameras()
        let world = SIMD3<Float>(-1.2, 0.9, 8.5)

        var observations: [(projection: [Double], point: SIMD2<Float>)] = []
        for camera in cameras {
            observations.append((
                try XCTUnwrap(Triangulation.projectionMatrix(for: camera)),
                try XCTUnwrap(Triangulation.project(world, with: camera))))
        }

        let recovered = try XCTUnwrap(Triangulation.triangulate(observations: observations))
        assertClose(recovered, world)
    }

    func testTriangulateNeedsAtLeastTwoViews() throws {
        let camera = makeCamera(name: "c", rvec: [0, 0, 0], tvec: [0, 0, 0])
        let projection = try XCTUnwrap(Triangulation.projectionMatrix(for: camera))
        XCTAssertNil(Triangulation.triangulate(
            observations: [(projection, SIMD2(740, 300))]))
        XCTAssertNil(Triangulation.triangulate(observations: []))
    }

    // MARK: - Instance3D

    func testInstance3DDefaultsToMissingPoints() {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
        let instance = Instance3D(skeleton: skeleton)
        XCTAssertEqual(instance.points.count, 2)
        XCTAssertTrue(instance.isEmpty)
        XCTAssertEqual(instance.nVisible, 0)
        XCTAssertFalse(instance.points[0].visible)
        XCTAssertTrue(instance.points[0].x.isNaN)
    }

    func testInstance3DSubscriptAndNumpy() {
        let a = Node(name: "a")
        let b = Node(name: "b")
        let skeleton = Skeleton(name: "s", nodes: [a, b])
        let instance = Instance3D(skeleton: skeleton)
        instance[a] = Point3D(x: 1, y: 2, z: 3, visible: true)
        instance["b"] = Point3D(x: 4, y: 5, z: 6, visible: true)

        XCTAssertEqual(instance.nVisible, 2)
        XCTAssertFalse(instance.isEmpty)
        XCTAssertEqual(instance[0].simd, SIMD3(1, 2, 3))
        XCTAssertEqual(instance[a].z, 3)

        let rows = instance.numpy()
        XCTAssertEqual(rows, [[1, 2, 3], [4, 5, 6]])

        // Missing node -> NaN row with invisibleAsNaN; raw coords otherwise.
        instance[b] = .missing
        let nanRows = instance.numpy()
        XCTAssertTrue(nanRows[1].allSatisfy { $0.isNaN })
        let rawRows = instance.numpy(invisibleAsNaN: false)
        XCTAssertTrue(rawRows[1].allSatisfy { $0.isNaN })  // stored coords are NaN too
    }

    // MARK: - InstanceGroup construction + triangulation

    /// Build an ``Instance`` whose 2D points are the projection of `world` points
    /// through `camera`.
    private func makeProjectedInstance(
        skeleton: Skeleton, world: [SIMD3<Float>], camera: Camera
    ) -> Instance {
        var pts: [Point] = []
        for w in world {
            let uv = Triangulation.project(w, with: camera)!
            pts.append(Point(x: uv.x, y: uv.y, visible: true, complete: true))
        }
        return Instance(skeleton: skeleton, points: PointsArray(points: pts))
    }

    func testInstanceGroupTriangulateRecovers3DPose() throws {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
        let world = [SIMD3<Float>(0.5, -0.4, 6.0), SIMD3<Float>(-0.8, 1.1, 7.5)]
        let cameras = makeThreeCameras()

        let group = InstanceGroup()
        for camera in cameras {
            group.instances[camera] = makeProjectedInstance(
                skeleton: skeleton, world: world, camera: camera)
        }

        let instance3D = try XCTUnwrap(group.triangulate())
        XCTAssertTrue(group.instance3D === instance3D)
        XCTAssertTrue(instance3D.skeleton === skeleton)
        XCTAssertEqual(instance3D.nVisible, 2)
        assertClose(instance3D.points[0].simd, world[0])
        assertClose(instance3D.points[1].simd, world[1])
    }

    func testInstanceGroupTriangulateSkipsUnderdeterminedNodes() throws {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
        let world = [SIMD3<Float>(0.5, -0.4, 6.0), SIMD3<Float>(-0.8, 1.1, 7.5)]
        let cameras = Array(makeThreeCameras().prefix(2))

        let group = InstanceGroup()
        for camera in cameras {
            group.instances[camera] = makeProjectedInstance(
                skeleton: skeleton, world: world, camera: camera)
        }
        // Hide node "b" in one of only two views -> only 1 view sees it -> missing.
        group.instances[cameras[0]]!.points.visibility[1] = false

        let instance3D = try XCTUnwrap(group.triangulate())
        XCTAssertTrue(instance3D.points[0].visible)
        XCTAssertFalse(instance3D.points[1].visible)
        XCTAssertEqual(instance3D.nVisible, 1)
    }

    func testInstanceGroupTriangulateReturnsNilWithoutCalibration() {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "a")])
        let group = InstanceGroup()
        // Cameras with no intrinsics/extrinsics -> no projection matrices.
        group.instances[Camera(name: "c0")] =
            Instance(skeleton: skeleton, points: PointsArray(points: [Point(x: 1, y: 2)]))
        group.instances[Camera(name: "c1")] =
            Instance(skeleton: skeleton, points: PointsArray(points: [Point(x: 3, y: 4)]))
        XCTAssertNil(group.triangulate())
        XCTAssertNil(group.instance3D)
    }

    func testInstanceGroupNumpyOrdersByCamera() {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
        let cam0 = Camera(name: "cam0")
        let cam1 = Camera(name: "cam1")
        let inst = Instance(skeleton: skeleton, points: PointsArray(points: [
            Point(x: 1, y: 2, visible: true),
            Point(x: 3, y: 4, visible: false),
        ]))
        let group = InstanceGroup(instances: [cam0: inst])

        let arr = group.numpy(cameras: [cam0, cam1])
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0][0], [1, 2])
        XCTAssertTrue(arr[0][1].allSatisfy { $0.isNaN })  // invisible point
        // cam1 absent from the group -> all-NaN slice sized to node count.
        XCTAssertEqual(arr[1].count, 2)
        XCTAssertTrue(arr[1].flatMap { $0 }.allSatisfy { $0.isNaN })
    }

    // MARK: - FrameGroup / RecordingSession construction

    func testFrameGroupConvenienceInit() {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "a")])
        let camera = Camera(name: "cam0")
        let video = Video(filename: "cam0.mp4")
        let instance = Instance(skeleton: skeleton, points: PointsArray(points: [Point(x: 1, y: 2)]))
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [instance])

        let group = InstanceGroup(instances: [camera: instance])
        let frameGroup = FrameGroup(frames: [camera: frame], instanceGroups: [group])

        XCTAssertEqual(frameGroup.frames.count, 1)
        XCTAssertEqual(frameGroup.instanceGroups.count, 1)
        XCTAssertTrue(frameGroup.frames[camera] === frame)
        XCTAssertTrue(frameGroup.instanceGroups[0].instances[camera] === instance)

        let session = RecordingSession(
            cameraToVideo: [camera: video], frameGroups: [frameGroup])
        XCTAssertEqual(session.cameraToVideo.count, 1)
        XCTAssertEqual(session.frameGroups.count, 1)
        XCTAssertTrue(session.frameGroups[0] === frameGroup)
    }

    func testFrameGroupTriangulatesAllInstanceGroups() throws {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
        let world = [SIMD3<Float>(0.3, -0.2, 5.5), SIMD3<Float>(-0.6, 0.7, 6.5)]
        let cameras = makeThreeCameras()

        let group0 = InstanceGroup()
        let group1 = InstanceGroup()
        for camera in cameras {
            group0.instances[camera] = makeProjectedInstance(
                skeleton: skeleton, world: world, camera: camera)
            group1.instances[camera] = makeProjectedInstance(
                skeleton: skeleton, world: world.map { $0 + SIMD3(1, 1, 1) }, camera: camera)
        }
        let frameGroup = FrameGroup(instanceGroups: [group0, group1])

        let results = frameGroup.triangulate()
        XCTAssertEqual(results.count, 2)
        XCTAssertNotNil(group0.instance3D)
        XCTAssertNotNil(group1.instance3D)
        assertClose(group0.instance3D!.points[0].simd, world[0])
        assertClose(group1.instance3D!.points[0].simd, world[0] + SIMD3(1, 1, 1))
    }
}
