import XCTest
import simd
@testable import SleapIO

final class DevM1FixTests: XCTestCase {

    private func makeSkeleton(name: String = "s") -> Skeleton {
        Skeleton(name: name, nodes: [Node(name: "body")])
    }

    private func makeVisibleInstance(skeleton: Skeleton, track: Track? = nil) -> Instance {
        let instance = Instance(skeleton: skeleton, track: track)
        instance.points[0] = Point(x: 1, y: 2, visible: true, complete: true)
        return instance
    }

    private func makeROI(_ name: String, videoIndex: Int? = nil, trackIndex: Int? = nil) -> ROI {
        var roi = ROI(
            annotationType: .boundingBox,
            name: name,
            points: [SIMD2<Float>(0, 0), SIMD2<Float>(10, 10)]
        )
        roi.videoIndex = videoIndex
        roi.trackIndex = trackIndex
        return roi
    }

    private func makeMask(_ name: String, videoIndex: Int? = nil, trackIndex: Int? = nil) -> SegmentationMask {
        var mask = SegmentationMask(rleCounts: [1, 1], height: 1, width: 2, name: name)
        mask.videoIndex = videoIndex
        mask.trackIndex = trackIndex
        return mask
    }

    func testCleanVideosRemapsAnnotationVideoIndicesAndDropsRemovedVideoAnnotations() throws {
        let skeleton = makeSkeleton()
        let removedVideo = Video(filename: "removed.mp4")
        let keptVideo = Video(filename: "kept.mp4")
        let frame = LabeledFrame(
            video: keptVideo,
            frameIndex: 0,
            instances: [makeVisibleInstance(skeleton: skeleton)]
        )
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [removedVideo, keptVideo],
            skeletons: [skeleton],
            tracks: [],
            rois: [
                makeROI("removed-roi", videoIndex: 0),
                makeROI("kept-roi", videoIndex: 1)
            ],
            masks: [
                makeMask("removed-mask", videoIndex: 0),
                makeMask("kept-mask", videoIndex: 1)
            ]
        )

        try labels.clean(frames: false, instances: false, skeletons: false, tracks: false, videos: true)

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertTrue(labels.videos[0] === keptVideo)
        XCTAssertEqual(labels.rois.map(\.name), ["kept-roi"])
        XCTAssertEqual(labels.getRois().first?.videoIndex, 0)
        XCTAssertEqual(labels.masks.map(\.name), ["kept-mask"])
        XCTAssertEqual(labels.getMasks().first?.videoIndex, 0)
    }

    func testCleanTracksRemapsAnnotationTrackIndicesAndNilsRemovedTracks() throws {
        let skeleton = makeSkeleton()
        let video = Video(filename: "tracks.mp4")
        let removedTrack = Track(name: "removed")
        let keptTrack = Track(name: "kept")
        let frame = LabeledFrame(
            video: video,
            frameIndex: 0,
            instances: [makeVisibleInstance(skeleton: skeleton, track: keptTrack)]
        )
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: [removedTrack, keptTrack],
            rois: [
                makeROI("removed-track-roi", trackIndex: 0),
                makeROI("kept-track-roi", trackIndex: 1)
            ],
            masks: [
                makeMask("removed-track-mask", trackIndex: 0),
                makeMask("kept-track-mask", trackIndex: 1)
            ]
        )

        try labels.clean(frames: false, instances: false, skeletons: false, tracks: true, videos: false)

        XCTAssertEqual(labels.tracks.count, 1)
        XCTAssertTrue(labels.tracks[0] === keptTrack)
        XCTAssertEqual(labels.rois.map(\.name), ["removed-track-roi", "kept-track-roi"])
        XCTAssertNil(labels.rois[0].trackIndex)
        XCTAssertEqual(labels.rois[1].trackIndex, 0)
        XCTAssertEqual(labels.masks.map(\.name), ["removed-track-mask", "kept-track-mask"])
        XCTAssertNil(labels.masks[0].trackIndex)
        XCTAssertEqual(labels.masks[1].trackIndex, 0)
    }

    func testCleanDefaultsMatchPythonParity() throws {
        let usedSkeleton = makeSkeleton(name: "used")
        let unusedSkeleton = makeSkeleton(name: "unused")
        let usedVideo = Video(filename: "used.mp4")
        let unreferencedVideo = Video(filename: "unreferenced.mp4")
        let unusedTrack = Track(name: "unused")
        let emptyInstance = Instance(skeleton: usedSkeleton)
        let frameWithEmptyInstance = LabeledFrame(
            video: usedVideo,
            frameIndex: 0,
            instances: [emptyInstance]
        )
        let emptyFrame = LabeledFrame(video: usedVideo, frameIndex: 1)
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frameWithEmptyInstance, emptyFrame]),
            videos: [usedVideo, unreferencedVideo],
            skeletons: [usedSkeleton, unusedSkeleton],
            tracks: [unusedTrack]
        )

        try labels.clean()

        XCTAssertEqual(labels.frameCount, 1)
        let survivingFrame = try XCTUnwrap(labels.frame(for: usedVideo, at: 0))
        XCTAssertTrue(survivingFrame.instances[0] === emptyInstance)
        XCTAssertEqual(labels.videos.count, 2)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertTrue(labels.skeletons[0] === usedSkeleton)
        XCTAssertTrue(labels.tracks.isEmpty)
        XCTAssertNil(labels.frame(for: usedVideo, at: 1))
    }

    func testRemovePredictionsDefaultCleansEmptyFramesAndUnusedIdentities() throws {
        let userSkeleton = makeSkeleton(name: "user")
        let predictionSkeleton = makeSkeleton(name: "prediction")
        let video = Video(filename: "predictions.mp4")
        let predictionTrack = Track(name: "prediction-track")
        let prediction = PredictedInstance(
            skeleton: predictionSkeleton,
            points: PredictedPointsArray(count: predictionSkeleton.nodes.count),
            score: 0.8,
            track: predictionTrack
        )
        let predictionOnlyFrame = LabeledFrame(video: video, frameIndex: 0, instances: [prediction])
        let userFrame = LabeledFrame(
            video: video,
            frameIndex: 1,
            instances: [makeVisibleInstance(skeleton: userSkeleton)]
        )
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [predictionOnlyFrame, userFrame]),
            videos: [video],
            skeletons: [userSkeleton, predictionSkeleton],
            tracks: [predictionTrack]
        )

        try labels.removePredictions()

        XCTAssertNil(labels.frame(for: video, at: 0))
        XCTAssertNotNil(labels.frame(for: video, at: 1))
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertTrue(labels.skeletons[0] === userSkeleton)
        XCTAssertTrue(labels.tracks.isEmpty)
    }

    func testReorderNodesSkipsDesyncedInstancesWithoutCrashing() throws {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "A"), Node(name: "B")])
        let instance = Instance(skeleton: skeleton)
        skeleton.addNode(Node(name: "C"))

        try skeleton.reorderNodes(["C", "A", "B"], migratingInstances: [instance])

        XCTAssertEqual(skeleton.nodeNames, ["C", "A", "B"])
        XCTAssertEqual(instance.points.count, 2)
    }
}
