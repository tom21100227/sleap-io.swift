import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// Tests for the M3 fidelity trio:
///   - #47: `/label_images` (`LabelImage`) round-trip — eager, lazy, and the
///     single-image (hyperslab) lazy read.
///   - #54: non-embedded `source_video` lineage survives save/load.
///   - #56: a lazily-loaded multiview session restores calibration + frame groups.
final class LabelImagesLineageTests: XCTestCase {

    // MARK: - Fixture helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_labelimages_\(UUID().uuidString).slp")
    }

    private func makeSkeleton() -> Skeleton {
        Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
    }

    private func makeInstance(_ skeleton: Skeleton, x: Float, y: Float) -> Instance {
        Instance(skeleton: skeleton, points: PointsArray(points: [
            Point(x: x, y: y, visible: true, complete: true),
            Point(x: x + 1, y: y + 1, visible: true, complete: true),
        ]))
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

    /// Two label images: a fully-populated one (objects, track/instance
    /// associations, explicit frame index) and a static one (nil frame index,
    /// single object).
    private func makeLabelImages() -> [LabelImage] {
        let li0 = LabelImage.from(
            rows: [[0, 1, 1], [2, 2, 0]],
            objects: [
                1: LabelImage.Info(trackIndex: 0, category: "cell", name: "c1"),
                2: LabelImage.Info(category: "glia", name: "c2", instanceIndex: 0),
            ],
            videoIndex: 0,
            frameIndex: 5,
            source: "cellpose")
        let li1 = LabelImage.from(
            rows: [[3, 0], [0, 3]],
            objects: [3: LabelImage.Info(category: "x")],
            videoIndex: 0,
            frameIndex: nil,
            source: "")
        return [li0, li1]
    }

    private func makeLabelsWithLabelImages() -> Labels {
        let skeleton = makeSkeleton()
        let video = Video(filename: "seg.mp4")
        let track = Track(name: "t0")
        let inst = makeInstance(skeleton, x: 1, y: 2)
        let frame = LabeledFrame(video: video, frameIndex: 5, instances: [inst])
        return Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: [track],
            labelImages: makeLabelImages())
    }

    // MARK: - Assertions

    private func assertLabelImagesEqual(
        _ got: [LabelImage], _ expected: [LabelImage],
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(got.count, expected.count, "label image count", file: file, line: line)
        guard got.count == expected.count else { return }
        for (g, e) in zip(got, expected) {
            XCTAssertEqual(g.data, e.data, "pixel data", file: file, line: line)
            XCTAssertEqual(g.height, e.height, "height", file: file, line: line)
            XCTAssertEqual(g.width, e.width, "width", file: file, line: line)
            XCTAssertEqual(g.videoIndex, e.videoIndex, "videoIndex", file: file, line: line)
            XCTAssertEqual(g.frameIndex, e.frameIndex, "frameIndex", file: file, line: line)
            XCTAssertEqual(g.source, e.source, "source", file: file, line: line)
            XCTAssertEqual(g.objects, e.objects, "objects", file: file, line: line)
        }
    }

    // MARK: - #47: label image round-trip (eager)

    func testLabelImageRoundTripEager() async throws {
        let labels = makeLabelsWithLabelImages()
        let expected = labels.labelImages
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await SLPWriter.write(labels, to: url.path)
        let reloaded = try await SLPReader.read(from: url.path)

        assertLabelImagesEqual(reloaded.labelImages, expected)

        // Spot-check the object associations survived intact.
        let li0 = try XCTUnwrap(reloaded.labelImages.first)
        XCTAssertEqual(li0.objects[1]?.trackIndex, 0)
        XCTAssertEqual(li0.objects[1]?.category, "cell")
        XCTAssertNil(li0.objects[1]?.instanceIndex)
        XCTAssertEqual(li0.objects[2]?.instanceIndex, 0)
        XCTAssertNil(li0.objects[2]?.trackIndex)
        XCTAssertEqual(li0.labelIDs, [1, 2])
        // The static image kept its nil frame index.
        XCTAssertNil(reloaded.labelImages[1].frameIndex)
    }

    // MARK: - #47: label image round-trip (lazy)

    func testLabelImageRoundTripLazy() async throws {
        let labels = makeLabelsWithLabelImages()
        let expected = labels.labelImages
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await SLPWriter.write(labels, to: url.path)
        let reloaded = try await SLPReader.readLazy(from: url.path)

        XCTAssertTrue(reloaded.isLazy)
        assertLabelImagesEqual(reloaded.labelImages, expected)
    }

    // MARK: - #47: lazy read of a single image via hyperslab

    func testLabelImageSingleImageHyperslabRead() async throws {
        let labels = makeLabelsWithLabelImages()
        let expected = labels.labelImages
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await SLPWriter.write(labels, to: url.path)

        // Read only the second image, without materializing the first's pixels.
        let file = try HDF5File.openReadOnly(path: url.path)
        let one = try XCTUnwrap(SLPReader.readLabelImage(from: file, at: 1))
        assertLabelImagesEqual([one], [expected[1]])

        // An out-of-range index yields nil rather than crashing.
        XCTAssertNil(SLPReader.readLabelImage(from: file, at: 99))
        XCTAssertNil(SLPReader.readLabelImage(from: file, at: -1))
    }

    /// A file that carries no label images loads with an empty collection (and no
    /// error) on both paths.
    func testNoLabelImagesLoadsEmpty() async throws {
        let skeleton = makeSkeleton()
        let video = Video(filename: "v.mp4")
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [makeInstance(skeleton, x: 0, y: 0)])
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video], skeletons: [skeleton], tracks: [])
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await SLPWriter.write(labels, to: url.path)
        let eager = try await SLPReader.read(from: url.path)
        let lazy = try await SLPReader.readLazy(from: url.path)
        XCTAssertTrue(eager.labelImages.isEmpty)
        XCTAssertTrue(lazy.labelImages.isEmpty)
    }

    // MARK: - #54: non-embedded source_video lineage

    func testNonEmbeddedSourceVideoRoundTrips() async throws {
        let skeleton = makeSkeleton()

        let external = Video(filename: "/data/original.mp4")
        external.frameCount = 100
        external.frameSize = (height: 480, width: 640, channels: 3)

        let derived = Video(filename: "/data/derived.mp4")
        derived.sourceVideo = external

        let frame = LabeledFrame(video: derived, frameIndex: 0, instances: [makeInstance(skeleton, x: 1, y: 1)])
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [derived], skeletons: [skeleton], tracks: [])

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SLPWriter.write(labels, to: url.path)

        for reloaded in [try await SLPReader.read(from: url.path),
                         try await SLPReader.readLazy(from: url.path)] {
            let video = try XCTUnwrap(reloaded.videos.first)
            let source = try XCTUnwrap(video.sourceVideo,
                                       "non-embedded source_video lineage must survive save")
            XCTAssertEqual(source.filename, "/data/original.mp4")
            // originalVideo walks the chain to the same root.
            XCTAssertEqual(video.originalVideo?.filename, "/data/original.mp4")
        }
    }

    /// A multi-level source-video chain is fully nested on save and rebuilt on load.
    func testMultiLevelSourceVideoChainRoundTrips() async throws {
        let skeleton = makeSkeleton()
        let root = Video(filename: "/data/root.mp4")
        let mid = Video(filename: "/data/mid.mp4")
        mid.sourceVideo = root
        let top = Video(filename: "/data/top.mp4")
        top.sourceVideo = mid

        let frame = LabeledFrame(video: top, frameIndex: 0, instances: [makeInstance(skeleton, x: 0, y: 0)])
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [top], skeletons: [skeleton], tracks: [])

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SLPWriter.write(labels, to: url.path)

        let reloaded = try await SLPReader.read(from: url.path)
        let video = try XCTUnwrap(reloaded.videos.first)
        XCTAssertEqual(video.sourceVideo?.filename, "/data/mid.mp4")
        XCTAssertEqual(video.sourceVideo?.sourceVideo?.filename, "/data/root.mp4")
        XCTAssertEqual(video.originalVideo?.filename, "/data/root.mp4")
    }

    // MARK: - #56: lazy-loaded session has calibration + frame groups

    func testLazyLoadedSessionHasCalibrationAndFrameGroups() async throws {
        let skeleton = makeSkeleton()
        let video0 = Video(filename: "camA.mp4")
        let video1 = Video(filename: "camB.mp4")
        let inst0 = makeInstance(skeleton, x: 1, y: 2)
        let inst1 = makeInstance(skeleton, x: 5, y: 6)
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
            sessions: [session])

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SLPWriter.write(labels, to: url.path)

        // The lazy path must restore calibration + the camera→video map + the
        // synchronized frame group (the #56 fix — previously the lazy reader only
        // recovered the legacy camera_to_video map with no calibration).
        let reloaded = try await SLPReader.readLazy(from: url.path)
        XCTAssertTrue(reloaded.isLazy)

        let restored = try XCTUnwrap(reloaded.sessions.first)
        XCTAssertEqual(restored.cameraToVideo.count, 2)

        var camByName: [String: Camera] = [:]
        for (cam, _) in restored.cameraToVideo { camByName[cam.name] = cam }
        let restoredCamA = try XCTUnwrap(camByName["camA"])
        // Calibration (intrinsics + extrinsics) survived on the lazy path.
        XCTAssertEqual(restoredCamA.matrix?.count, 9)
        XCTAssertEqual(restoredCamA.size?.width, 1280)
        XCTAssertEqual(restoredCamA.rvec?.count, 3)
        XCTAssertNotNil(restoredCamA.distortionCoefficients)

        // Frame group restored and its frames are identity-stable with the lazy
        // frame store (the group referenced frame is the very object `labels[i]`
        // returns).
        XCTAssertEqual(restored.frameGroups.count, 1)
        let restoredGroup = restored.frameGroups[0]
        XCTAssertEqual(restoredGroup.instanceGroups.count, 1)
        XCTAssertEqual(restoredGroup.instanceGroups[0].instances.count, 2)

        var frameByCamName: [String: LabeledFrame] = [:]
        for (cam, frame) in restoredGroup.frames { frameByCamName[cam.name] = frame }
        XCTAssertTrue(frameByCamName["camA"] === reloaded.frameStore.frame(at: 0))
        XCTAssertTrue(frameByCamName["camB"] === reloaded.frameStore.frame(at: 1))
    }

    /// Calibration also round-trips on the eager path (guards against the shared
    /// ``SessionSchema/makeSession`` refactor regressing the eager reader).
    func testEagerSessionCalibrationStillRoundTrips() async throws {
        let skeleton = makeSkeleton()
        let video0 = Video(filename: "camA.mp4")
        let frame0 = LabeledFrame(video: video0, frameIndex: 0, instances: [makeInstance(skeleton, x: 1, y: 2)])
        let camA = makeCalibratedCamera(name: "camA", seed: 3)
        let session = RecordingSession()
        session.cameraToVideo[camA] = video0

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame0]),
            videos: [video0], skeletons: [skeleton], tracks: [], sessions: [session])

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await SLPWriter.write(labels, to: url.path)

        let reloaded = try await SLPReader.read(from: url.path)
        let restored = try XCTUnwrap(reloaded.sessions.first)
        let (cam, _) = try XCTUnwrap(restored.cameraToVideo.first)
        XCTAssertEqual(cam.name, "camA")
        XCTAssertEqual(cam.matrix?.count, 9)
    }
}
