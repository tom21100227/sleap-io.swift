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
