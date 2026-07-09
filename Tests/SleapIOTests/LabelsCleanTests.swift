import XCTest
@testable import SleapIO

final class LabelsCleanTests: XCTestCase {

    // MARK: - Helpers

    /// A skeleton with a single node, used across the tests.
    private func makeSkeleton(name: String = "fly") -> Skeleton {
        Skeleton(name: name, nodes: [Node(name: "body")])
    }

    /// Build a user instance with all points invisible (empty).
    private func makeEmptyInstance(skeleton: Skeleton, track: Track? = nil) -> Instance {
        // Default PointsArray has visibility = false for every node, so this is empty.
        Instance(skeleton: skeleton, track: track)
    }

    /// Build a user instance with at least one visible point.
    private func makeVisibleInstance(skeleton: Skeleton, track: Track? = nil) -> Instance {
        let instance = Instance(skeleton: skeleton, track: track)
        instance.points[0] = Point(x: 1, y: 2, visible: true, complete: true)
        return instance
    }

    /// Build a predicted instance with at least one visible point.
    private func makeVisiblePrediction(skeleton: Skeleton,
                                       score: Float = 0.9,
                                       track: Track? = nil) -> PredictedInstance {
        var pts = PredictedPointsArray(count: skeleton.nodes.count)
        pts[0] = PredictedPoint(
            point: Point(x: 3, y: 4, visible: true, complete: true),
            score: 0.8
        )
        return PredictedInstance(skeleton: skeleton, points: pts, score: score, track: track)
    }

    // MARK: - frames: empty removed, negative preserved

    func testCleanRemovesEmptyFramesButKeepsNegativeFrames() throws {
        let skeleton = makeSkeleton()
        let video = Video(filename: "clean.mp4")

        // Frame 0: a visible instance -> kept.
        let keptFrame = LabeledFrame(
            video: video,
            frameIndex: 0,
            instances: [makeVisibleInstance(skeleton: skeleton)]
        )
        // Frame 1: only an empty (all-invisible) instance -> becomes empty -> removed.
        let emptyFrame = LabeledFrame(
            video: video,
            frameIndex: 1,
            instances: [makeEmptyInstance(skeleton: skeleton)]
        )
        // Frame 2: empty but explicitly negative -> preserved.
        let negativeFrame = LabeledFrame(
            video: video,
            frameIndex: 2,
            instances: [],
            isNegative: true
        )

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [keptFrame, emptyFrame, negativeFrame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        try labels.clean(instances: true)

        let frameIndices = labels.map { $0.frameIndex }.sorted()
        XCTAssertEqual(frameIndices, [0, 2])
        XCTAssertNil(labels.frame(for: video, at: 1))
        // The negative frame survives even though it has no instances.
        let survivingNegative = try XCTUnwrap(labels.frame(for: video, at: 2))
        XCTAssertTrue(survivingNegative.isNegative)
    }

    // MARK: - instances: no-visible-point instances removed

    func testCleanRemovesInstancesWithNoVisiblePoints() throws {
        let skeleton = makeSkeleton()
        let video = Video(filename: "clean.mp4")

        let visible = makeVisibleInstance(skeleton: skeleton)
        let empty = makeEmptyInstance(skeleton: skeleton)
        let frame = LabeledFrame(
            video: video,
            frameIndex: 0,
            instances: [visible, empty]
        )

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        try labels.clean(instances: true)

        let survivingFrame = try XCTUnwrap(labels.frame(for: video, at: 0))
        XCTAssertEqual(survivingFrame.instances.count, 1)
        XCTAssertTrue(survivingFrame.instances[0] === visible)
    }

    func testCleanWithInstancesFalseKeepsEmptyInstances() throws {
        let skeleton = makeSkeleton()
        let video = Video(filename: "clean.mp4")

        let empty = makeEmptyInstance(skeleton: skeleton)
        let frame = LabeledFrame(
            video: video,
            frameIndex: 0,
            instances: [empty]
        )

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        // With instances pruning disabled, the empty instance (and thus its frame) survives.
        try labels.clean(frames: false, instances: false)

        let survivingFrame = try XCTUnwrap(labels.frame(for: video, at: 0))
        XCTAssertEqual(survivingFrame.instances.count, 1)
    }

    // MARK: - identity tables: unused entries pruned

    func testCleanPrunesUnusedTrackSkeletonVideo() throws {
        let usedSkeleton = makeSkeleton(name: "used")
        let unusedSkeleton = makeSkeleton(name: "unused")
        let usedVideo = Video(filename: "used.mp4")
        let unusedVideo = Video(filename: "unused.mp4")
        let usedTrack = Track(name: "used")
        let unusedTrack = Track(name: "unused")

        let frame = LabeledFrame(
            video: usedVideo,
            frameIndex: 0,
            instances: [makeVisibleInstance(skeleton: usedSkeleton, track: usedTrack)]
        )

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [usedVideo, unusedVideo],
            skeletons: [usedSkeleton, unusedSkeleton],
            tracks: [usedTrack, unusedTrack]
        )

        try labels.clean(videos: true)

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertTrue(labels.videos[0] === usedVideo)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertTrue(labels.skeletons[0] === usedSkeleton)
        XCTAssertEqual(labels.tracks.count, 1)
        XCTAssertTrue(labels.tracks[0] === usedTrack)
    }

    func testCleanKeepsUnusedIdentitiesWhenFlagsDisabled() throws {
        let usedSkeleton = makeSkeleton(name: "used")
        let unusedSkeleton = makeSkeleton(name: "unused")
        let usedVideo = Video(filename: "used.mp4")
        let unusedVideo = Video(filename: "unused.mp4")
        let usedTrack = Track(name: "used")
        let unusedTrack = Track(name: "unused")

        let frame = LabeledFrame(
            video: usedVideo,
            frameIndex: 0,
            instances: [makeVisibleInstance(skeleton: usedSkeleton, track: usedTrack)]
        )

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [usedVideo, unusedVideo],
            skeletons: [usedSkeleton, unusedSkeleton],
            tracks: [usedTrack, unusedTrack]
        )

        try labels.clean(skeletons: false, tracks: false, videos: false)

        XCTAssertEqual(labels.videos.count, 2)
        XCTAssertEqual(labels.skeletons.count, 2)
        XCTAssertEqual(labels.tracks.count, 2)
    }

    // MARK: - removePredictions

    func testRemovePredictionsStripsPredictedKeepsUser() throws {
        let skeleton = makeSkeleton()
        let video = Video(filename: "clean.mp4")

        let user = makeVisibleInstance(skeleton: skeleton)
        let prediction = makeVisiblePrediction(skeleton: skeleton)
        let frame = LabeledFrame(
            video: video,
            frameIndex: 0,
            instances: [user, prediction]
        )

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        try labels.removePredictions()

        let survivingFrame = try XCTUnwrap(labels.frame(for: video, at: 0))
        XCTAssertEqual(survivingFrame.predictedInstances.count, 0)
        XCTAssertEqual(survivingFrame.userInstances.count, 1)
        XCTAssertTrue(survivingFrame.instances[0] === user)
    }

    func testRemovePredictionsWithCleanPrunesUnusedTrackAndEmptyFrame() throws {
        let skeleton = makeSkeleton()
        let video = Video(filename: "clean.mp4")
        let predictionOnlyTrack = Track(name: "pred-only")

        // Frame 0: only a prediction (on its own track). After removePredictions it is empty,
        // and with clean=true the frame and its track should be pruned.
        let prediction = makeVisiblePrediction(skeleton: skeleton, track: predictionOnlyTrack)
        let predFrame = LabeledFrame(
            video: video,
            frameIndex: 0,
            instances: [prediction]
        )
        // Frame 1: a user instance -> survives.
        let userFrame = LabeledFrame(
            video: video,
            frameIndex: 1,
            instances: [makeVisibleInstance(skeleton: skeleton)]
        )

        let labels = Labels(
            frameStore: EagerFrameStore(frames: [predFrame, userFrame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: [predictionOnlyTrack]
        )

        try labels.removePredictions(clean: true)

        // Prediction-only frame removed, user frame kept.
        XCTAssertNil(labels.frame(for: video, at: 0))
        XCTAssertNotNil(labels.frame(for: video, at: 1))
        XCTAssertEqual(labels.frameCount, 1)
        // The track that only a prediction referenced is pruned.
        XCTAssertEqual(labels.tracks.count, 0)
    }

    // MARK: - lazy stores are materialized transparently

    func testCleanMaterializesWhenLazy() throws {
        let skeleton = makeSkeleton()
        let video = Video(filename: "clean.mp4")
        let frame = LabeledFrame(
            video: video,
            frameIndex: 0,
            instances: [makeVisibleInstance(skeleton: skeleton)]
        )

        let labels = Labels(
            frameStore: LazyStub(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )
        XCTAssertTrue(labels.isLazy)

        try labels.clean()

        XCTAssertFalse(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 1)
    }
}

/// A minimal lazy frame store used to verify `clean()` materializes before mutating.
private final class LazyStub: FrameStore, @unchecked Sendable {
    private let frames: [LabeledFrame]
    init(frames: [LabeledFrame]) { self.frames = frames }
    var count: Int { frames.count }
    func frame(at index: Int) -> LabeledFrame { frames[index] }
    var isLazy: Bool { true }
    func allFrames() -> [LabeledFrame] { frames }
    var totalInstanceCount: Int { frames.reduce(0) { $0 + $1.instances.count } }
    var totalPredictedInstanceCount: Int {
        frames.reduce(0) { $0 + $1.predictedInstances.count }
    }
}
