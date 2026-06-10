import XCTest
@testable import SleapIO

/// E2.5: LabeledFrame cleanup + classification helpers.
///
/// Upstream reference: `LabeledFrame.remove_empty_instances`,
/// `remove_predictions`, `unused_predictions`, `is_user_labeled`.
final class LabeledFrameAccessorsTests: XCTestCase {

    // MARK: - Helpers

    /// A 2-node skeleton used across the tests.
    private func makeSkeleton() -> Skeleton {
        Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
    }

    private func makeVideo() -> Video {
        Video(filename: "v.mp4")
    }

    /// A user instance whose points all match `visible`.
    private func makeUserInstance(skeleton: Skeleton, visible: Bool) -> Instance {
        let inst = Instance(skeleton: skeleton)
        for i in 0..<inst.points.count {
            inst.points[i] = Point(x: Float(i), y: Float(i), visible: visible)
        }
        return inst
    }

    /// A predicted instance whose points all match `visible`.
    private func makePredictedInstance(skeleton: Skeleton, visible: Bool) -> PredictedInstance {
        var pts = PredictedPointsArray(count: skeleton.nodes.count)
        for i in 0..<pts.count {
            pts[i] = PredictedPoint(
                point: Point(x: Float(i), y: Float(i), visible: visible),
                score: 0.9
            )
        }
        return PredictedInstance(skeleton: skeleton, points: pts, score: 0.9)
    }

    // MARK: - Instance.isEmpty

    func testInstanceIsEmpty_trueWhenNoVisiblePoints() {
        let skel = makeSkeleton()
        XCTAssertTrue(makeUserInstance(skeleton: skel, visible: false).isEmpty)
        XCTAssertFalse(makeUserInstance(skeleton: skel, visible: true).isEmpty)
    }

    // MARK: - removeEmptyInstances

    func testRemoveEmptyInstances_dropsAllInvisibleKeepsVisible() {
        let skel = makeSkeleton()
        let video = makeVideo()

        let visible = makeUserInstance(skeleton: skel, visible: true)
        let invisible = makeUserInstance(skeleton: skel, visible: false)
        let predictedVisible = makePredictedInstance(skeleton: skel, visible: true)
        let predictedEmpty = makePredictedInstance(skeleton: skel, visible: false)

        let frame = LabeledFrame(
            video: video,
            frameIndex: 0,
            instances: [visible, invisible, predictedVisible, predictedEmpty]
        )

        frame.removeEmptyInstances()

        XCTAssertEqual(frame.instances.count, 2)
        XCTAssertTrue(frame.instances.contains { $0 === visible })
        XCTAssertTrue(frame.instances.contains { $0 === predictedVisible })
        XCTAssertFalse(frame.instances.contains { $0 === invisible })
        XCTAssertFalse(frame.instances.contains { $0 === predictedEmpty })
    }

    func testRemoveEmptyInstances_noopWhenAllVisible() {
        let skel = makeSkeleton()
        let a = makeUserInstance(skeleton: skel, visible: true)
        let b = makeUserInstance(skeleton: skel, visible: true)
        let frame = LabeledFrame(video: makeVideo(), frameIndex: 1, instances: [a, b])

        frame.removeEmptyInstances()

        XCTAssertEqual(frame.instances.count, 2)
    }

    // MARK: - removePredictions

    func testRemovePredictions_keepsUserInstances() {
        let skel = makeSkeleton()
        let user1 = makeUserInstance(skeleton: skel, visible: true)
        let user2 = makeUserInstance(skeleton: skel, visible: false)
        let pred1 = makePredictedInstance(skeleton: skel, visible: true)
        let pred2 = makePredictedInstance(skeleton: skel, visible: true)

        let frame = LabeledFrame(
            video: makeVideo(),
            frameIndex: 2,
            instances: [user1, pred1, user2, pred2]
        )

        frame.removePredictions()

        XCTAssertEqual(frame.instances.count, 2)
        XCTAssertTrue(frame.instances.contains { $0 === user1 })
        XCTAssertTrue(frame.instances.contains { $0 === user2 })
        XCTAssertTrue(frame.predictedInstances.isEmpty)
    }

    func testRemovePredictions_removesAllWhenOnlyPredictions() {
        let skel = makeSkeleton()
        let frame = LabeledFrame(
            video: makeVideo(),
            frameIndex: 3,
            instances: [
                makePredictedInstance(skeleton: skel, visible: true),
                makePredictedInstance(skeleton: skel, visible: true)
            ]
        )

        frame.removePredictions()

        XCTAssertTrue(frame.instances.isEmpty)
    }

    // MARK: - unusedPredictions

    func testUnusedPredictions_excludesPredictionAUserWasCreatedFrom() {
        let skel = makeSkeleton()
        let usedPrediction = makePredictedInstance(skeleton: skel, visible: true)
        let unusedPrediction = makePredictedInstance(skeleton: skel, visible: true)

        // A user instance that was created from `usedPrediction`.
        let user = Instance(skeleton: skel, fromPredicted: usedPrediction)

        let frame = LabeledFrame(
            video: makeVideo(),
            frameIndex: 4,
            instances: [usedPrediction, unusedPrediction, user]
        )

        let unused = frame.unusedPredictions

        XCTAssertEqual(unused.count, 1)
        XCTAssertTrue(unused.contains { $0 === unusedPrediction })
        XCTAssertFalse(unused.contains { $0 === usedPrediction })
    }

    func testUnusedPredictions_allWhenNoUserReferences() {
        let skel = makeSkeleton()
        let pred1 = makePredictedInstance(skeleton: skel, visible: true)
        let pred2 = makePredictedInstance(skeleton: skel, visible: true)
        let frame = LabeledFrame(
            video: makeVideo(),
            frameIndex: 5,
            instances: [pred1, pred2]
        )

        XCTAssertEqual(frame.unusedPredictions.count, 2)
    }

    func testUnusedPredictions_emptyWhenNoPredictions() {
        let skel = makeSkeleton()
        let frame = LabeledFrame(
            video: makeVideo(),
            frameIndex: 6,
            instances: [makeUserInstance(skeleton: skel, visible: true)]
        )

        XCTAssertTrue(frame.unusedPredictions.isEmpty)
    }

    // MARK: - isUserLabeled

    func testIsUserLabeled_trueWhenUserInstanceExists() {
        let skel = makeSkeleton()
        let frame = LabeledFrame(
            video: makeVideo(),
            frameIndex: 7,
            instances: [
                makePredictedInstance(skeleton: skel, visible: true),
                makeUserInstance(skeleton: skel, visible: true)
            ]
        )

        XCTAssertTrue(frame.isUserLabeled)
    }

    func testIsUserLabeled_falseWhenOnlyPredictions() {
        let skel = makeSkeleton()
        let frame = LabeledFrame(
            video: makeVideo(),
            frameIndex: 8,
            instances: [makePredictedInstance(skeleton: skel, visible: true)]
        )

        XCTAssertFalse(frame.isUserLabeled)
    }

    func testIsUserLabeled_falseWhenEmpty() {
        let frame = LabeledFrame(video: makeVideo(), frameIndex: 9)
        XCTAssertFalse(frame.isUserLabeled)
    }
}
