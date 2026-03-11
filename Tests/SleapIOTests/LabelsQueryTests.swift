import XCTest
@testable import SleapIO

/// Q01: Query semantics tests.
final class LabelsQueryTests: XCTestCase {

    // Helper to build a minimal eager Labels with multiple videos, frames, and tracks.
    private func makeTestLabels() -> (Labels, Video, Video, Track, Track) {
        let videoA = Video(filename: "videoA.mp4")
        let videoB = Video(filename: "videoB.mp4")

        let trackX = Track(name: "track_x")
        let trackY = Track(name: "track_y")

        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
        ])

        // Frames for videoA: indices 5, 2, 8 (intentionally out of order)
        let frameA5 = LabeledFrame(video: videoA, frameIndex: 5, instances: [
            Instance(skeleton: skeleton, track: trackX),
        ])
        let frameA2 = LabeledFrame(video: videoA, frameIndex: 2, instances: [
            Instance(skeleton: skeleton, track: trackY),
        ])
        let frameA8 = LabeledFrame(video: videoA, frameIndex: 8, instances: [
            Instance(skeleton: skeleton, track: trackX),
            Instance(skeleton: skeleton, track: trackY),
        ])

        // Frames for videoB: index 0
        let frameB0 = LabeledFrame(video: videoB, frameIndex: 0, instances: [
            Instance(skeleton: skeleton, track: trackX),
        ])

        let store = EagerFrameStore(frames: [frameA5, frameA2, frameA8, frameB0])
        let labels = Labels(
            frameStore: store,
            videos: [videoA, videoB],
            skeletons: [skeleton],
            tracks: [trackX, trackY]
        )

        return (labels, videoA, videoB, trackX, trackY)
    }

    // MARK: - Q01: frames(for:) returns sorted frames

    func testQ01_framesForVideoReturnsSortedByFrameIndex() {
        let (labels, videoA, _, _, _) = makeTestLabels()

        let framesA = labels.frames(for: videoA)

        // Should be sorted by frame index
        XCTAssertEqual(framesA.count, 3)
        XCTAssertEqual(framesA[0].frameIndex, 2)
        XCTAssertEqual(framesA[1].frameIndex, 5)
        XCTAssertEqual(framesA[2].frameIndex, 8)

        // All should reference videoA
        for frame in framesA {
            XCTAssertTrue(frame.video === videoA)
        }
    }

    func testQ01_framesForVideoReturnsCorrectSubset() {
        let (labels, _, videoB, _, _) = makeTestLabels()

        let framesB = labels.frames(for: videoB)
        XCTAssertEqual(framesB.count, 1)
        XCTAssertEqual(framesB[0].frameIndex, 0)
        XCTAssertTrue(framesB[0].video === videoB)
    }

    func testQ01_framesForUnknownVideoReturnsEmpty() {
        let (labels, _, _, _, _) = makeTestLabels()
        let unknownVideo = Video(filename: "unknown.mp4")
        let frames = labels.frames(for: unknownVideo)
        XCTAssertTrue(frames.isEmpty)
    }

    // MARK: - Q01: frame(for:at:) identity stability

    func testQ01_frameForVideoAtIndexReturnsSameObject() {
        let (labels, videoA, _, _, _) = makeTestLabels()

        let frame1 = labels.frame(for: videoA, at: 5)
        let frame2 = labels.frame(for: videoA, at: 5)

        XCTAssertNotNil(frame1)
        XCTAssertNotNil(frame2)
        XCTAssertTrue(
            frame1 === frame2,
            "Repeated frame(for:at:) calls must return the same cached LabeledFrame object"
        )
    }

    func testQ01_frameForVideoAtNonexistentIndexReturnsNil() {
        let (labels, videoA, _, _, _) = makeTestLabels()

        let frame = labels.frame(for: videoA, at: 999)
        XCTAssertNil(frame, "Non-existent frame index should return nil")
    }

    // MARK: - Q01: instances(for:) track query

    func testQ01_instancesForTrackReturnsAllMatchingInstances() {
        let (labels, _, _, trackX, trackY) = makeTestLabels()

        let instancesX = labels.instances(for: trackX)
        // trackX appears in frameA5 (1), frameA8 (1), frameB0 (1) = 3
        XCTAssertEqual(instancesX.count, 3)
        for inst in instancesX {
            XCTAssertTrue(inst.track === trackX)
        }

        let instancesY = labels.instances(for: trackY)
        // trackY appears in frameA2 (1), frameA8 (1) = 2
        XCTAssertEqual(instancesY.count, 2)
        for inst in instancesY {
            XCTAssertTrue(inst.track === trackY)
        }
    }

    func testQ01_instancesForUnusedTrackReturnsEmpty() {
        let (labels, _, _, _, _) = makeTestLabels()

        let unusedTrack = Track(name: "unused")
        let instances = labels.instances(for: unusedTrack)
        XCTAssertTrue(instances.isEmpty)
    }

    // MARK: - Collection conformance

    func testLabelsRandomAccessCollectionConformance() {
        let (labels, _, _, _, _) = makeTestLabels()

        XCTAssertEqual(labels.count, 4)
        XCTAssertEqual(labels.startIndex, 0)
        XCTAssertEqual(labels.endIndex, 4)

        // Subscript access
        for i in labels.startIndex..<labels.endIndex {
            let frame = labels[i]
            XCTAssertNotNil(frame)
        }
    }

    func testLabelsSubscriptIdentityStability() {
        let (labels, _, _, _, _) = makeTestLabels()

        // Accessing the same index should return the same object
        let frame0a = labels[0]
        let frame0b = labels[0]
        XCTAssertTrue(frame0a === frame0b)
    }

    // MARK: - Convenience properties

    func testLabelsConvenienceProperties() {
        let (labels, videoA, _, _, _) = makeTestLabels()

        XCTAssertTrue(labels.video === videoA, "Primary video should be first in list")
        XCTAssertNotNil(labels.skeleton)
        XCTAssertEqual(labels.frameCount, 4)
        XCTAssertEqual(labels.instanceCount, 5)  // 1+1+2+1
    }

    func testLabeledFrameIndicesForVideo() {
        let (labels, videoA, _, _, _) = makeTestLabels()

        let indices = labels.labeledFrameIndices(for: videoA)
        XCTAssertTrue(indices.contains(2))
        XCTAssertTrue(indices.contains(5))
        XCTAssertTrue(indices.contains(8))
        XCTAssertEqual(indices.count, 3)
    }
}
