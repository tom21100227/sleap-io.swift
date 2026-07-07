import XCTest
@testable import SleapIO

final class LabelsMergeTests: XCTestCase {
    private func makeLabelsForMerge() -> (Labels, Labels, PredictedInstance) {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
        let video = Video(filename: "merge.mp4")

        // Base user instance and incoming user instance share a pose, so they are
        // spatial duplicates and dedup to a single user instance.
        let baseFrame = LabeledFrame(
            video: video,
            frameIndex: 3,
            instances: [Instance.from(numpy: [[10, 10]], skeleton: skeleton)]
        )

        // The incoming prediction is at a distinct location, so it is not a
        // duplicate and gets added.
        let incomingPrediction = PredictedInstance.from(
            numpy: [[100, 100]], skeleton: skeleton, score: 0.9)
        let incomingFrame = LabeledFrame(
            video: video,
            frameIndex: 3,
            instances: [
                Instance.from(numpy: [[10, 10]], skeleton: skeleton),
                incomingPrediction,
            ]
        )

        let base = Labels(
            frameStore: EagerFrameStore(frames: [baseFrame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )
        let other = Labels(
            frameStore: EagerFrameStore(frames: [incomingFrame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        return (base, other, incomingPrediction)
    }

    func testMergeAutoKeepsExistingUsersAndAddsPredictions() throws {
        let (base, other, incomingPrediction) = makeLabelsForMerge()

        try base.merge(from: other, strategy: .auto)

        let mergedFrame = try XCTUnwrap(base.frame(for: base.videos[0], at: 3))
        XCTAssertEqual(mergedFrame.userInstances.count, 1)
        XCTAssertEqual(mergedFrame.predictedInstances.count, 1)
        XCTAssertTrue(mergedFrame.predictedInstances[0] === incomingPrediction)
    }
}

/// Frame-level cascade + conflict-reporting tests for ``LabeledFrame/merge``.
///
/// Named to be exercised by both `--filter LabelsMergeTests` (same file) and
/// `--filter LabeledFrame`.
final class LabeledFrameMergeTests: XCTestCase {

    private let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
    private let video = Video(filename: "merge.mp4")

    private func user(_ x: Float, _ y: Float, track: Track? = nil) -> Instance {
        Instance.from(numpy: [[x, y]], skeleton: skeleton, track: track)
    }

    private func pred(_ x: Float, _ y: Float, score: Float = 0.9,
                      track: Track? = nil) -> PredictedInstance {
        PredictedInstance.from(numpy: [[x, y]], skeleton: skeleton,
                               score: score, track: track)
    }

    private func frame(_ instances: [Instance], negative: Bool = false) -> LabeledFrame {
        LabeledFrame(video: video, frameIndex: 3, instances: instances,
                     isNegative: negative)
    }

    // MARK: - auto: spatial dedup + conflict reporting

    func testAutoDedupsDuplicateUsersAndReportsConflict() throws {
        let base = frame([user(10, 10)])
        let incoming = frame([user(10, 10)])

        let conflicts = try base.merge(from: incoming, strategy: .auto)

        XCTAssertEqual(base.userInstances.count, 1)
        XCTAssertEqual(base.predictedInstances.count, 0)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].conflictType, .duplicateInstance)
        XCTAssertEqual(conflicts[0].resolution, .keptOriginal)
        XCTAssertTrue(conflicts[0].frame === base)
    }

    func testAutoAddsNonDuplicateInstanceWithoutConflict() throws {
        let base = frame([user(10, 10)])
        let incoming = frame([user(100, 100)])

        let conflicts = try base.merge(from: incoming, strategy: .auto)

        XCTAssertEqual(base.userInstances.count, 2)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testAutoReplacesPredictionWithMatchingUser() throws {
        let base = frame([pred(10, 10)])
        let incomingUser = user(10, 10)
        let incoming = frame([incomingUser])

        let conflicts = try base.merge(from: incoming, strategy: .auto)

        XCTAssertEqual(base.userInstances.count, 1)
        XCTAssertEqual(base.predictedInstances.count, 0)
        XCTAssertTrue(base.instances[0] === incomingUser)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].resolution, .keptNew)
    }

    func testAutoKeepsUserOverMatchingPrediction() throws {
        let baseUser = user(10, 10)
        let base = frame([baseUser])
        let incoming = frame([pred(10, 10)])

        let conflicts = try base.merge(from: incoming, strategy: .auto)

        XCTAssertEqual(base.userInstances.count, 1)
        XCTAssertEqual(base.predictedInstances.count, 0)
        XCTAssertTrue(base.instances[0] === baseUser)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].resolution, .keptOriginal)
    }

    func testAutoKeepsIncomingPredictionOverMatchingPrediction() throws {
        let base = frame([pred(10, 10, score: 0.1)])
        let incomingPred = pred(10, 10, score: 0.99)
        let incoming = frame([incomingPred])

        let conflicts = try base.merge(from: incoming, strategy: .auto)

        XCTAssertEqual(base.predictedInstances.count, 1)
        XCTAssertTrue(base.instances[0] === incomingPred)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].resolution, .keptNew)
    }

    // MARK: - keepBoth / keepOriginal / keepNew

    func testKeepBothAppendsAllAndReportsNoConflicts() throws {
        let base = frame([user(10, 10)])
        let incoming = frame([user(10, 10), pred(10, 10)])

        let conflicts = try base.merge(from: incoming, strategy: .keepBoth)

        XCTAssertEqual(base.instances.count, 3)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testKeepOriginalKeepsSelfAndReportsNoConflicts() throws {
        let baseUser = user(10, 10)
        let base = frame([baseUser])
        let incoming = frame([user(10, 10), pred(100, 100)])

        let conflicts = try base.merge(from: incoming, strategy: .keepOriginal)

        XCTAssertEqual(base.instances.count, 1)
        XCTAssertTrue(base.instances[0] === baseUser)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testKeepNewReplacesInstances() throws {
        let base = frame([user(10, 10)])
        let incomingUser = user(50, 50)
        let incomingPred = pred(60, 60)
        let incoming = frame([incomingUser, incomingPred])

        let conflicts = try base.merge(from: incoming, strategy: .keepNew)

        XCTAssertEqual(base.instances.count, 2)
        XCTAssertTrue(base.instances[0] === incomingUser)
        XCTAssertTrue(base.instances[1] === incomingPred)
        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - replacePredictions

    func testReplacePredictionsKeepsUsersAndSwapsPredictions() throws {
        let baseUser = user(10, 10)
        let basePred = pred(10, 10, score: 0.1)
        let base = frame([baseUser, basePred])
        let incomingUser = user(20, 20)  // dropped: only incoming predictions are added
        let incomingPred = pred(30, 30, score: 0.8)
        let incoming = frame([incomingUser, incomingPred])

        let conflicts = try base.merge(from: incoming, strategy: .replacePredictions)

        XCTAssertEqual(base.userInstances.count, 1)
        XCTAssertTrue(base.userInstances[0] === baseUser)
        XCTAssertEqual(base.predictedInstances.count, 1)
        XCTAssertTrue(base.predictedInstances[0] === incomingPred)
        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - updateTracks

    func testUpdateTracksPropagatesTrackAndScoreWithoutAddingInstances() throws {
        let baseUser = user(10, 10)
        let base = frame([baseUser])
        let track = Track(name: "1")
        let incomingUser = user(10, 10, track: track)
        incomingUser.trackingScore = 0.75
        let incoming = frame([incomingUser])

        let conflicts = try base.merge(from: incoming, strategy: .updateTracks)

        XCTAssertEqual(base.instances.count, 1)
        XCTAssertTrue(base.instances[0] === baseUser)
        XCTAssertTrue(baseUser.track === track)
        XCTAssertEqual(baseUser.trackingScore, 0.75)
        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - isNegative resolution

    func testNegativeFrameClearedWhenPopulatedAndReportsConflict() throws {
        let base = frame([], negative: true)
        let incoming = frame([user(10, 10)])

        let conflicts = try base.merge(from: incoming, strategy: .auto)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        XCTAssertTrue(conflicts.contains { $0.conflictType == .other("negativeFrame") })
    }

    func testBothNegativeAndEmptyStaysNegative() throws {
        let base = frame([], negative: true)
        let incoming = frame([], negative: true)

        let conflicts = try base.merge(from: incoming, strategy: .auto)

        XCTAssertTrue(base.isNegative)
        XCTAssertTrue(base.instances.isEmpty)
        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - matcher configurability + discardable result

    func testIdentityMatcherDedupsByTrackNotPose() throws {
        let track = Track(name: "1")
        let base = frame([user(10, 10, track: track)])
        // Different pose but same track object: matches under the identity matcher.
        let incoming = frame([user(500, 500, track: track)])

        let conflicts = try base.merge(
            from: incoming, strategy: .auto, instanceMatcher: .identity)

        XCTAssertEqual(base.userInstances.count, 1)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].resolution, .keptOriginal)
    }

    func testResultIsDiscardable() throws {
        let base = frame([user(10, 10)])
        let incoming = frame([user(100, 100)])
        // Should compile without capturing the return value (@discardableResult).
        try base.merge(from: incoming, strategy: .auto)
        XCTAssertEqual(base.userInstances.count, 2)
    }
}

/// Thread-safe collector for progress fractions reported during a merge.
private final class ProgressCollector: @unchecked Sendable {
    private(set) var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
}

/// ``Labels/merge`` result, matcher-driven dedup, and provenance-history tests.
///
/// Named to be exercised by `--filter LabelsMerge`.
final class LabelsMergeResultTests: XCTestCase {
    private func makeOverlappingProjects() -> (Labels, Labels, PredictedInstance) {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
        let video = Video(filename: "merge.mp4")

        let baseFrame = LabeledFrame(
            video: video,
            frameIndex: 3,
            instances: [Instance.from(numpy: [[10, 10]], skeleton: skeleton)]
        )
        let incomingPrediction = PredictedInstance.from(
            numpy: [[100, 100]], skeleton: skeleton, score: 0.9)
        let incomingFrame = LabeledFrame(
            video: video,
            frameIndex: 3,
            instances: [
                Instance.from(numpy: [[10, 10]], skeleton: skeleton),
                incomingPrediction,
            ]
        )
        let base = Labels(
            frameStore: EagerFrameStore(frames: [baseFrame]),
            videos: [video], skeletons: [skeleton], tracks: [])
        let other = Labels(
            frameStore: EagerFrameStore(frames: [incomingFrame]),
            videos: [video], skeletons: [skeleton], tracks: [])
        return (base, other, incomingPrediction)
    }

    // MARK: - MergeResult counts

    func testMergeReturnsResultWithCounts() throws {
        let (base, other, _) = makeOverlappingProjects()

        let result = try base.merge(from: other, strategy: .auto)

        XCTAssertTrue(result.successful)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.framesMerged, 1)
        XCTAssertEqual(result.instancesAdded, 1)      // the non-duplicate prediction
        XCTAssertEqual(result.instancesSkipped, 1)    // the duplicate user (kept original)
        XCTAssertEqual(result.instancesUpdated, 0)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.conflicts[0].resolution, .keptOriginal)
    }

    func testMergeAddsNewFrameCountsAllInstances() throws {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
        let video = Video(filename: "v.mp4")
        let base = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [video], skeletons: [skeleton], tracks: [])
        let otherFrame = LabeledFrame(
            video: video, frameIndex: 7,
            instances: [
                Instance.from(numpy: [[1, 1]], skeleton: skeleton),
                Instance.from(numpy: [[2, 2]], skeleton: skeleton),
            ])
        let other = Labels(
            frameStore: EagerFrameStore(frames: [otherFrame]),
            videos: [video], skeletons: [skeleton], tracks: [])

        let result = try base.merge(from: other)

        XCTAssertEqual(result.framesMerged, 1)
        XCTAssertEqual(result.instancesAdded, 2)
        XCTAssertEqual(base.frameCount, 1)
        let f = try XCTUnwrap(base.frame(for: video, at: 7))
        XCTAssertEqual(f.instances.count, 2)
    }

    // MARK: - Matcher-driven dedup + remapping

    func testMergeDedupsVideoWithSamePathAndRegistersFrameUnderLocalVideo() throws {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
        let baseVideo = Video(filename: "shared.mp4")
        let otherVideo = Video(filename: "shared.mp4")  // same path, different object
        let base = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [baseVideo], skeletons: [skeleton], tracks: [])
        let otherFrame = LabeledFrame(
            video: otherVideo, frameIndex: 5,
            instances: [Instance.from(numpy: [[1, 1]], skeleton: skeleton)])
        let other = Labels(
            frameStore: EagerFrameStore(frames: [otherFrame]),
            videos: [otherVideo], skeletons: [skeleton], tracks: [])

        let result = try base.merge(from: other)

        XCTAssertEqual(base.videos.count, 1)
        XCTAssertTrue(base.videos[0] === baseVideo)
        XCTAssertEqual(result.framesMerged, 1)
        let f = try XCTUnwrap(base.frame(for: baseVideo, at: 5))
        XCTAssertTrue(f.video === baseVideo)
        XCTAssertEqual(f.instances.count, 1)
    }

    func testMergeAppendsUnmatchedVideo() throws {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
        let baseVideo = Video(filename: "a.mp4")
        let otherVideo = Video(filename: "b.mp4")
        let base = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [baseVideo], skeletons: [skeleton], tracks: [])
        let otherFrame = LabeledFrame(
            video: otherVideo, frameIndex: 0,
            instances: [Instance.from(numpy: [[1, 1]], skeleton: skeleton)])
        let other = Labels(
            frameStore: EagerFrameStore(frames: [otherFrame]),
            videos: [otherVideo], skeletons: [skeleton], tracks: [])

        try base.merge(from: other)

        XCTAssertEqual(base.videos.count, 2)
    }

    func testMergeRemapsInstanceSkeletonOntoMatchedLocal() throws {
        let baseSkel = Skeleton(name: "A", nodes: [Node(name: "head"), Node(name: "tail")])
        let otherSkel = Skeleton(name: "B", nodes: [Node(name: "head"), Node(name: "tail")])
        let baseVideo = Video(filename: "v.mp4")
        let otherVideo = Video(filename: "v.mp4")
        let base = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [baseVideo], skeletons: [baseSkel], tracks: [])
        let inst = Instance.from(numpy: [[1, 1], [2, 2]], skeleton: otherSkel)
        let otherFrame = LabeledFrame(
            video: otherVideo, frameIndex: 0, instances: [inst])
        let other = Labels(
            frameStore: EagerFrameStore(frames: [otherFrame]),
            videos: [otherVideo], skeletons: [otherSkel], tracks: [])

        let result = try base.merge(from: other)

        XCTAssertTrue(result.successful)
        XCTAssertEqual(base.skeletons.count, 1)
        XCTAssertTrue(base.skeletons[0] === baseSkel)
        let f = try XCTUnwrap(base.frame(for: baseVideo, at: 0))
        XCTAssertTrue(f.instances[0].skeleton === baseSkel)
    }

    func testMergeRemapsInstanceTrackOntoMatchedLocal() throws {
        let skeleton = Skeleton(name: "A", nodes: [Node(name: "body")])
        let baseTrack = Track(name: "1")
        let otherTrack = Track(name: "1")
        let baseVideo = Video(filename: "v.mp4")
        let otherVideo = Video(filename: "v.mp4")
        let base = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [baseVideo], skeletons: [skeleton], tracks: [baseTrack])
        let inst = Instance.from(numpy: [[1, 1]], skeleton: skeleton, track: otherTrack)
        let otherFrame = LabeledFrame(
            video: otherVideo, frameIndex: 0, instances: [inst])
        let other = Labels(
            frameStore: EagerFrameStore(frames: [otherFrame]),
            videos: [otherVideo], skeletons: [skeleton], tracks: [otherTrack])

        try base.merge(from: other)

        XCTAssertEqual(base.tracks.count, 1)
        XCTAssertTrue(base.tracks[0] === baseTrack)
        let f = try XCTUnwrap(base.frame(for: baseVideo, at: 0))
        XCTAssertTrue(f.instances[0].track === baseTrack)
    }

    // MARK: - Provenance history

    func testMergeRecordsHistoryInProvenance() throws {
        let (base, other, _) = makeOverlappingProjects()

        try base.merge(from: other, strategy: .auto)

        let history = try XCTUnwrap(base.provenance["merge_history"]?.arrayValue)
        XCTAssertEqual(history.count, 1)
        let record = try XCTUnwrap(history[0].objectValue)
        XCTAssertEqual(record["strategy"]?.stringValue, "auto")
        let sourceLabels = try XCTUnwrap(record["source_labels"]?.objectValue)
        XCTAssertEqual(sourceLabels["n_frames"]?.intValue, 1)
        XCTAssertEqual(sourceLabels["n_skeletons"]?.intValue, 1)
        let resultRecord = try XCTUnwrap(record["result"]?.objectValue)
        XCTAssertEqual(resultRecord["frames_merged"]?.intValue, 1)
        XCTAssertEqual(resultRecord["instances_added"]?.intValue, 1)

        // A second merge appends another record.
        try base.merge(from: other, strategy: .keepBoth)
        XCTAssertEqual(base.provenance["merge_history"]?.arrayValue?.count, 2)
        let second = try XCTUnwrap(base.provenance["merge_history"]?.arrayValue?[1].objectValue)
        XCTAssertEqual(second["strategy"]?.stringValue, "keep_both")
    }

    // MARK: - Progress

    func testMergeReportsProgress() throws {
        let (base, other, _) = makeOverlappingProjects()
        let collector = ProgressCollector()

        try base.merge(from: other, progress: { collector.record($0) })

        XCTAssertFalse(collector.values.isEmpty)
        XCTAssertEqual(collector.values.last, 1.0)
    }
}
