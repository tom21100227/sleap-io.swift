import XCTest
@testable import SleapIO

final class LabelsMergeTests: XCTestCase {
    private func makeLabelsForMerge() -> (Labels, Labels, PredictedInstance) {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
        let video = Video(filename: "merge.mp4")

        let baseFrame = LabeledFrame(
            video: video,
            frameIndex: 3,
            instances: [Instance(skeleton: skeleton)]
        )

        let incomingPrediction = PredictedInstance(
            skeleton: skeleton,
            points: PredictedPointsArray(count: skeleton.nodes.count),
            score: 0.9
        )
        let incomingFrame = LabeledFrame(
            video: video,
            frameIndex: 3,
            instances: [
                Instance(skeleton: skeleton),
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

    func testMergeUpdateTracksKeepsExistingUsersAndAddsPredictions() throws {
        let (base, other, incomingPrediction) = makeLabelsForMerge()

        try base.merge(from: other, strategy: .updateTracks)

        let mergedFrame = try XCTUnwrap(base.frame(for: base.videos[0], at: 3))
        XCTAssertEqual(mergedFrame.userInstances.count, 1)
        XCTAssertEqual(mergedFrame.predictedInstances.count, 1)
        XCTAssertTrue(mergedFrame.predictedInstances[0] === incomingPrediction)
    }
}
