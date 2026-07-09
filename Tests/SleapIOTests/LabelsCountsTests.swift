import XCTest
@testable import SleapIO

/// E1.5: Labels count accessors.
final class LabelsCountsTests: XCTestCase {

    private func makeLabels() throws -> (Labels, Skeleton, Video, Video, Track, Track) {
        let skel = Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
        let v1 = Video(filename: "v1.mp4")
        let v2 = Video(filename: "v2.mp4")
        let t1 = Track(name: "t1")
        let t2 = Track(name: "t2")
        let labels = Labels()

        // v1 frame 0: 1 user (t1) + 1 predicted (t2)
        let f0 = LabeledFrame(video: v1, frameIndex: 0)
        f0.instances.append(Instance(skeleton: skel, track: t1))
        f0.instances.append(PredictedInstance(skeleton: skel,
                                              points: PredictedPointsArray(count: 2),
                                              score: 0.5, track: t2))
        // v1 frame 1: 1 user (t1), no user-vs-pred mix
        let f1 = LabeledFrame(video: v1, frameIndex: 1)
        f1.instances.append(Instance(skeleton: skel, track: t1))
        // v2 frame 0: empty (no instances)
        let f2 = LabeledFrame(video: v2, frameIndex: 0)

        try labels.addFrame(f0)
        try labels.addFrame(f1)
        try labels.addFrame(f2)
        return (labels, skel, v1, v2, t1, t2)
    }

    func testUserAndPredictedCounts() throws {
        let (labels, _, _, _, _, _) = try makeLabels()
        XCTAssertEqual(labels.nUserInstances, 2) // f0 user + f1 user
        XCTAssertEqual(labels.nPredInstances, 1) // f0 predicted
    }

    func testFramesPerVideo() throws {
        let (labels, _, v1, v2, _, _) = try makeLabels()
        let counts = labels.nFramesPerVideo()
        XCTAssertEqual(counts[v1], 2)
        XCTAssertEqual(counts[v2], 1)
    }

    func testInstancesPerTrack() throws {
        let (labels, _, _, _, t1, t2) = try makeLabels()
        let counts = labels.nInstancesPerTrack()
        XCTAssertEqual(counts[t1], 2) // f0 + f1
        XCTAssertEqual(counts[t2], 1) // f0 predicted
    }

    func testUserLabeledFrames() throws {
        let (labels, _, v1, _, _, _) = try makeLabels()
        let frames = labels.userLabeledFrames
        XCTAssertEqual(frames.count, 2) // f0 and f1 have user instances; f2 empty
        XCTAssertTrue(frames.allSatisfy { $0.video === v1 })
    }
}
