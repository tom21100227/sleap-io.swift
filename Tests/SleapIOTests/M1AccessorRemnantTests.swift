import XCTest
import simd
@testable import SleapIO

final class M1AccessorRemnantTests: XCTestCase {
    private func makeROI(_ name: String, videoIndex: Int? = nil, frameIndex: Int? = nil) -> ROI {
        var roi = ROI(
            annotationType: .boundingBox,
            name: name,
            points: [SIMD2<Float>(0, 0), SIMD2<Float>(1, 1)]
        )
        roi.videoIndex = videoIndex
        roi.frameIndex = frameIndex
        return roi
    }

    private func makeMask(_ name: String, videoIndex: Int? = nil, frameIndex: Int? = nil) -> SegmentationMask {
        var mask = SegmentationMask(rleCounts: [1, 1], height: 1, width: 2, name: name)
        mask.videoIndex = videoIndex
        mask.frameIndex = frameIndex
        return mask
    }

    func testLabelsLiteralSubscriptsDelegateToExistingLookups() {
        let videoA = Video(filename: "a.mp4")
        let videoB = Video(filename: "b.mp4")

        let frameA5 = LabeledFrame(video: videoA, frameIndex: 5)
        let frameA1 = LabeledFrame(video: videoA, frameIndex: 1)
        let frameB3 = LabeledFrame(video: videoB, frameIndex: 3)
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frameA5, frameB3, frameA1]),
            videos: [videoA, videoB],
            skeletons: [],
            tracks: []
        )

        XCTAssertEqual(labels[videoA].map(\.frameIndex), [1, 5])
        XCTAssertTrue(labels[videoA, 5] === labels.find(video: videoA, frameIdx: 5).first)
        XCTAssertTrue(labels[videoA, 999] == nil)
        XCTAssertTrue(labels[[0, 1]] == [frameA5, frameB3])
        let rangeFrames: [LabeledFrame] = labels[0..<2]
        XCTAssertTrue(rangeFrames == [frameA5, frameB3])
    }

    func testRoiAndMaskQueriesFilterByVideoAndFrame() {
        let videoA = Video(filename: "a.mp4")
        let videoB = Video(filename: "b.mp4")
        let unknown = Video(filename: "unknown.mp4")

        let roiA0 = makeROI("roi-a0", videoIndex: 0, frameIndex: 0)
        let roiA1 = makeROI("roi-a1", videoIndex: 0, frameIndex: 1)
        let roiB0 = makeROI("roi-b0", videoIndex: 1, frameIndex: 0)
        let roiFrameOnly = makeROI("roi-frame-only", frameIndex: 0)
        let maskA0 = makeMask("mask-a0", videoIndex: 0, frameIndex: 0)
        let maskA1 = makeMask("mask-a1", videoIndex: 0, frameIndex: 1)
        let maskB0 = makeMask("mask-b0", videoIndex: 1, frameIndex: 0)
        let maskFrameOnly = makeMask("mask-frame-only", frameIndex: 0)

        let labels = Labels(
            frameStore: EagerFrameStore(),
            videos: [videoA, videoB],
            skeletons: [],
            tracks: [],
            rois: [roiA0, roiA1, roiB0, roiFrameOnly],
            masks: [maskA0, maskA1, maskB0, maskFrameOnly]
        )

        XCTAssertEqual(labels.getRois(), labels.rois)
        XCTAssertEqual(labels.getMasks(), labels.masks)
        XCTAssertEqual(labels.getRois(video: videoA).map(\.name), ["roi-a0", "roi-a1"])
        XCTAssertEqual(labels.getMasks(video: videoB).map(\.name), ["mask-b0"])
        XCTAssertEqual(labels.getRois(frameIndex: 0).map(\.name), ["roi-a0", "roi-b0", "roi-frame-only"])
        XCTAssertEqual(labels.getMasks(frameIndex: 0).map(\.name), ["mask-a0", "mask-b0", "mask-frame-only"])
        XCTAssertEqual(labels.getRois(video: videoA, frameIndex: 1).map(\.name), ["roi-a1"])
        XCTAssertEqual(labels.getMasks(video: videoA, frameIndex: 1).map(\.name), ["mask-a1"])
        XCTAssertTrue(labels.getRois(video: unknown).isEmpty)
        XCTAssertTrue(labels.getMasks(video: unknown).isEmpty)
    }
}
