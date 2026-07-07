import XCTest
@testable import SleapIO

/// E5.4 (#37): Tests for the M2 matching/merge result value types.
///
/// Upstream reference: `sleap_io/model/matching.py`
/// (`MatchResult`, `MergeResult`, `ConflictResolution`, `FrameStrategy`).
///
/// These cover construction, equality, and computed conveniences only — the
/// matcher/merge algorithms are implemented in later issues.
final class MatchingResultTypesTests: XCTestCase {

    // MARK: - Helpers

    private func makeVideo(_ name: String) -> Video { Video(filename: name) }
    private func makeSkeleton(_ name: String) -> Skeleton { Skeleton(name: name) }
    private func makeTrack(_ name: String) -> Track { Track(name: name) }
    private func makeFrame(index: Int = 0) -> LabeledFrame {
        LabeledFrame(video: makeVideo("v.mp4"), frameIndex: index)
    }

    // MARK: - FrameStrategy parity alias

    func testFrameStrategyIsMergeStrategyAlias() {
        // FrameStrategy must be the exact same type as LabeledFrame.MergeStrategy,
        // not a competing duplicate.
        let strategy: FrameStrategy = .replacePredictions
        let same: LabeledFrame.MergeStrategy = strategy
        XCTAssertEqual(same, .replacePredictions)

        // All upstream FrameStrategy cases are representable.
        let all: [FrameStrategy] = [
            .auto, .keepOriginal, .keepNew, .keepBoth, .updateTracks, .replacePredictions,
        ]
        XCTAssertEqual(all.count, 6)
    }

    // MARK: - MatchResult

    func testMatchResultDefaultsAreEmpty() {
        let result = MatchResult()
        XCTAssertTrue(result.videoMap.isEmpty)
        XCTAssertTrue(result.skeletonMap.isEmpty)
        XCTAssertTrue(result.trackMap.isEmpty)
        XCTAssertTrue(result.allVideosMatched)
        XCTAssertTrue(result.allSkeletonsMatched)
        XCTAssertTrue(result.allTracksMatched)
        XCTAssertEqual(result.nVideosMatched, 0)
    }

    func testMatchResultUnmatchedAndCounts() {
        let v1 = makeVideo("a.mp4")
        let v2 = makeVideo("b.mp4")
        let selfVideo = makeVideo("a_local.mp4")

        let s1 = makeSkeleton("skel")
        let selfSkel = makeSkeleton("skel_local")

        let t1 = makeTrack("track1")

        // v1 matched to selfVideo, v2 unmatched.
        // s1 matched. t1 unmatched.
        let result = MatchResult(
            videoMap: [v1: selfVideo, v2: nil],
            skeletonMap: [s1: selfSkel],
            trackMap: [t1: nil]
        )

        XCTAssertEqual(result.nVideosMatched, 1)
        XCTAssertEqual(result.unmatchedVideos, [v2])
        XCTAssertFalse(result.allVideosMatched)

        XCTAssertEqual(result.nSkeletonsMatched, 1)
        XCTAssertTrue(result.unmatchedSkeletons.isEmpty)
        XCTAssertTrue(result.allSkeletonsMatched)

        XCTAssertEqual(result.nTracksMatched, 0)
        XCTAssertEqual(result.unmatchedTracks, [t1])
        XCTAssertFalse(result.allTracksMatched)
    }

    func testMatchResultSummaryReportsRatios() {
        let v1 = makeVideo("a.mp4")
        let v2 = makeVideo("b.mp4")
        let result = MatchResult(videoMap: [v1: makeVideo("x"), v2: nil])
        let summary = result.summary()
        XCTAssertTrue(summary.contains("Videos: 1/2 matched"), summary)
        XCTAssertTrue(summary.contains("Skeletons: 0/0 matched"), summary)
    }

    func testMatchResultEquatable() {
        let v = makeVideo("a.mp4")
        let selfV = makeVideo("b.mp4")
        let a = MatchResult(videoMap: [v: selfV])
        let b = MatchResult(videoMap: [v: selfV])
        XCTAssertEqual(a, b)

        let c = MatchResult(videoMap: [v: nil])
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ConflictResolution

    func testConflictResolutionConstruction() {
        let frame = makeFrame(index: 7)
        let conflict = ConflictResolution(
            frame: frame,
            conflictType: .duplicateInstance,
            resolution: .keptBoth,
            details: "two overlapping poses"
        )
        XCTAssertEqual(conflict.frame.frameIndex, 7)
        XCTAssertEqual(conflict.conflictType, .duplicateInstance)
        XCTAssertEqual(conflict.resolution, .keptBoth)
        XCTAssertEqual(conflict.details, "two overlapping poses")
    }

    func testConflictResolutionDefaultsAndOtherCase() {
        let frame = makeFrame()
        let conflict = ConflictResolution(
            frame: frame,
            conflictType: .other("custom_kind"),
            resolution: .keptOriginal
        )
        XCTAssertNil(conflict.details)
        XCTAssertEqual(conflict.conflictType, .other("custom_kind"))
        XCTAssertNotEqual(conflict.conflictType, .other("different"))
    }

    func testConflictResolutionEquatable() {
        let frame = makeFrame(index: 3)
        let a = ConflictResolution(frame: frame, conflictType: .skeletonMismatch, resolution: .keptNew)
        let b = ConflictResolution(frame: frame, conflictType: .skeletonMismatch, resolution: .keptNew)
        XCTAssertEqual(a, b)

        // Different frame identity breaks equality (LabeledFrame is identity-equated).
        let c = ConflictResolution(frame: makeFrame(index: 3), conflictType: .skeletonMismatch, resolution: .keptNew)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - MergeResult

    func testMergeResultDefaults() {
        let result = MergeResult(successful: true)
        XCTAssertTrue(result.successful)
        XCTAssertEqual(result.framesMerged, 0)
        XCTAssertEqual(result.instancesAdded, 0)
        XCTAssertEqual(result.instancesUpdated, 0)
        XCTAssertEqual(result.instancesSkipped, 0)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testMergeResultCarriesCountsConflictsAndErrors() {
        let frame = makeFrame(index: 1)
        let conflict = ConflictResolution(
            frame: frame,
            conflictType: .trackConflict,
            resolution: .updatedTracks
        )
        let result = MergeResult(
            successful: false,
            framesMerged: 4,
            instancesAdded: 10,
            instancesUpdated: 2,
            instancesSkipped: 1,
            conflicts: [conflict],
            errors: [
                .mergeConflict(description: "pose clash"),
                .skeletonMismatch(expected: ["a", "b"], found: ["a"]),
            ]
        )
        XCTAssertFalse(result.successful)
        XCTAssertEqual(result.framesMerged, 4)
        XCTAssertEqual(result.instancesAdded, 10)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.errors.count, 2)
        // Errors reuse the existing RecoverableSleapError vocabulary.
        XCTAssertEqual(result.errors.first, .mergeConflict(description: "pose clash"))
    }

    func testMergeResultSummary() {
        let success = MergeResult(successful: true, framesMerged: 3, instancesAdded: 5)
        let summary = success.summary()
        XCTAssertTrue(summary.contains("Merge completed successfully"), summary)
        XCTAssertTrue(summary.contains("Frames merged: 3"), summary)
        XCTAssertTrue(summary.contains("Instances added: 5"), summary)
        XCTAssertFalse(summary.contains("Instances updated"), summary)

        let failure = MergeResult(
            successful: false,
            errors: [.mergeConflict(description: "boom")]
        )
        let failSummary = failure.summary()
        XCTAssertTrue(failSummary.contains("Merge completed with errors"), failSummary)
        XCTAssertTrue(failSummary.contains("Errors encountered: 1"), failSummary)
    }

    func testMergeResultEquatable() {
        let a = MergeResult(successful: true, framesMerged: 2)
        let b = MergeResult(successful: true, framesMerged: 2)
        XCTAssertEqual(a, b)

        let c = MergeResult(successful: true, framesMerged: 3)
        XCTAssertNotEqual(a, c)
    }
}
