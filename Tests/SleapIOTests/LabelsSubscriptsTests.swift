import XCTest
@testable import SleapIO

/// E1.2: Labels subscripts + find() with foreign-video resolution.
///
/// Mirrors the upstream sleap-io `Labels.__getitem__` / `find` / `match_video`
/// behavior: a `Video` passed in from a different object graph (same filename,
/// different identity) is resolved against the local identity table before
/// querying frames.
final class LabelsSubscriptsTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a minimal eager Labels with two videos, out-of-order frames,
    /// and a single skeleton.
    private func makeTestLabels() -> (Labels, Video, Video) {
        let videoA = Video(filename: "videoA.mp4")
        let videoB = Video(filename: "videoB.mp4")

        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
        ])

        // Frames for videoA: indices 5, 2, 8 (intentionally out of order).
        let frameA5 = LabeledFrame(video: videoA, frameIndex: 5, instances: [
            Instance(skeleton: skeleton),
        ])
        let frameA2 = LabeledFrame(video: videoA, frameIndex: 2, instances: [
            Instance(skeleton: skeleton),
        ])
        let frameA8 = LabeledFrame(video: videoA, frameIndex: 8, instances: [
            Instance(skeleton: skeleton),
            Instance(skeleton: skeleton),
        ])

        // Frames for videoB: index 0.
        let frameB0 = LabeledFrame(video: videoB, frameIndex: 0, instances: [
            Instance(skeleton: skeleton),
        ])

        let store = EagerFrameStore(frames: [frameA5, frameA2, frameA8, frameB0])
        let labels = Labels(
            frameStore: store,
            videos: [videoA, videoB],
            skeletons: [skeleton],
            tracks: []
        )

        return (labels, videoA, videoB)
    }

    // MARK: - resolveVideo

    func testResolveVideo_sameIdentityReturnsSameObject() {
        let (labels, videoA, _) = makeTestLabels()
        let resolved = labels.resolveVideo(videoA)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved === videoA, "Identical object should resolve to itself")
    }

    func testResolveVideo_foreignObjectMapsToLocalByFilename() {
        let (labels, videoA, _) = makeTestLabels()

        // A foreign Video with the same filename but a distinct identity.
        let foreignA = Video(filename: "videoA.mp4")
        XCTAssertFalse(foreignA === videoA, "Sanity: foreign video is a distinct object")

        let resolved = labels.resolveVideo(foreignA)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(
            resolved === videoA,
            "Foreign video with matching filename must resolve to the local video object"
        )
    }

    func testResolveVideo_unknownFilenameReturnsNil() {
        let (labels, _, _) = makeTestLabels()
        let unknown = Video(filename: "does-not-exist.mp4")
        XCTAssertNil(labels.resolveVideo(unknown))
    }

    // MARK: - frames(forVideoMatching:)

    func testFramesForVideoMatching_foreignObjectReturnsRightFramesSorted() {
        let (labels, videoA, _) = makeTestLabels()

        // Foreign object, same filename as videoA.
        let foreignA = Video(filename: "videoA.mp4")

        let frames = labels.frames(forVideoMatching: foreignA)
        XCTAssertEqual(frames.count, 3)
        // Sorted by frame index.
        XCTAssertEqual(frames.map { $0.frameIndex }, [2, 5, 8])
        // Resolved to the local video identity.
        for frame in frames {
            XCTAssertTrue(frame.video === videoA)
        }
    }

    func testFramesForVideoMatching_sameObjectReturnsRightFrames() {
        let (labels, _, videoB) = makeTestLabels()
        let frames = labels.frames(forVideoMatching: videoB)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameIndex, 0)
        XCTAssertTrue(frames[0].video === videoB)
    }

    func testFramesForVideoMatching_unknownVideoReturnsEmpty() {
        let (labels, _, _) = makeTestLabels()
        let unknown = Video(filename: "unknown.mp4")
        XCTAssertTrue(labels.frames(forVideoMatching: unknown).isEmpty)
    }

    // MARK: - find (frameIdx == nil)

    func testFind_nilFrameIdxReturnsAllFramesSorted() {
        let (labels, videoA, _) = makeTestLabels()

        let frames = labels.find(video: videoA)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map { $0.frameIndex }, [2, 5, 8])
        for frame in frames {
            XCTAssertTrue(frame.video === videoA)
        }
    }

    func testFind_nilFrameIdxWithForeignVideoResolves() {
        let (labels, videoA, _) = makeTestLabels()
        let foreignA = Video(filename: "videoA.mp4")

        let frames = labels.find(video: foreignA)
        XCTAssertEqual(frames.map { $0.frameIndex }, [2, 5, 8])
        for frame in frames {
            XCTAssertTrue(frame.video === videoA)
        }
    }

    // MARK: - find (frameIdx != nil)

    func testFind_specificFrameIdxReturnsMatchingFrame() {
        let (labels, videoA, _) = makeTestLabels()

        let frames = labels.find(video: videoA, frameIdx: 5)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameIndex, 5)
        XCTAssertTrue(frames[0].video === videoA)
    }

    func testFind_specificFrameIdxWithForeignVideoResolves() {
        let (labels, videoA, _) = makeTestLabels()
        let foreignA = Video(filename: "videoA.mp4")

        let frames = labels.find(video: foreignA, frameIdx: 8)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameIndex, 8)
        XCTAssertTrue(frames[0].video === videoA)
    }

    func testFind_missingFrameIdxWithoutReturnNewReturnsEmpty() {
        let (labels, videoA, _) = makeTestLabels()

        let frames = labels.find(video: videoA, frameIdx: 999)
        XCTAssertTrue(frames.isEmpty, "No frame and returnNew=false should return empty")
    }

    func testFind_missingFrameIdxWithReturnNewCreatesEmptyFrame() {
        let (labels, videoA, _) = makeTestLabels()

        let beforeCount = labels.frameCount
        let frames = labels.find(video: videoA, frameIdx: 999, returnNew: true)

        XCTAssertEqual(frames.count, 1)
        let newFrame = frames[0]
        XCTAssertEqual(newFrame.frameIndex, 999)
        XCTAssertTrue(newFrame.video === videoA, "New frame must use the resolved local video")
        XCTAssertTrue(newFrame.instances.isEmpty, "New frame must be empty")

        // The store must NOT have been mutated.
        XCTAssertEqual(labels.frameCount, beforeCount, "find(returnNew:) must not add to the store")
        XCTAssertNil(
            labels.frame(for: videoA, at: 999),
            "The freshly-created frame must not be persisted in the store"
        )
    }

    func testFind_returnNewWithForeignVideoUsesResolvedVideo() {
        let (labels, videoA, _) = makeTestLabels()
        let foreignA = Video(filename: "videoA.mp4")

        let frames = labels.find(video: foreignA, frameIdx: 1234, returnNew: true)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(
            frames[0].video === videoA,
            "returnNew with a foreign video must build the frame on the resolved local video"
        )
    }

    func testFind_returnNewForUnknownVideoReturnsEmpty() {
        let (labels, _, _) = makeTestLabels()
        let unknown = Video(filename: "unknown.mp4")

        // The video cannot be resolved, so there is nothing to anchor a new frame to.
        let frames = labels.find(video: unknown, frameIdx: 5, returnNew: true)
        XCTAssertTrue(frames.isEmpty, "Unresolvable video should yield no frame even with returnNew")
    }

    func testFind_existingFrameWithReturnNewReturnsExistingNotNew() {
        let (labels, videoA, _) = makeTestLabels()

        let existing = labels.frame(for: videoA, at: 5)
        XCTAssertNotNil(existing)

        let frames = labels.find(video: videoA, frameIdx: 5, returnNew: true)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(
            frames[0] === existing,
            "When a frame already exists, returnNew must return the existing object, not a fresh one"
        )
    }
}
