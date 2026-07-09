import XCTest
@testable import SleapIO

/// E5.2: Tests for ``InstanceMatcher`` and the ``Instance`` correspondence
/// helpers (`samePoseAs`, `sameIdentityAs`, `overlapsWith` / `boundingBoxIoU`).
///
/// Upstream reference: `sleap_io/model/matching.py` (`InstanceMatcher`,
/// `InstanceMatchMethod`) and `Instance.same_pose_as` / `same_identity_as` /
/// `overlaps_with`.
final class InstanceMatcherTests: XCTestCase {

    // MARK: - Helpers

    /// A skeleton whose four nodes sit at the corners of a bounding box.
    private func boxSkeleton(_ name: String = "box") -> Skeleton {
        Skeleton(name: name, nodes: ["tl", "tr", "br", "bl"].map { Node(name: $0) })
    }

    /// A two-node skeleton for pose-distance tests.
    private func pairSkeleton(_ name: String = "pair") -> Skeleton {
        Skeleton(name: name, nodes: ["a", "b"].map { Node(name: $0) })
    }

    /// Build an instance whose visible points span the axis-aligned box
    /// `[x0, y0] – [x1, y1]` (one point per corner).
    private func boxInstance(
        _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float,
        skeleton: Skeleton,
        track: Track? = nil
    ) -> Instance {
        Instance.from(
            numpy: [[x0, y0], [x1, y0], [x1, y1], [x0, y1]],
            skeleton: skeleton,
            track: track
        )
    }

    // MARK: - boundingBoxIoU / overlapsWith

    func testIoUIdenticalInstancesIsOne() {
        let skel = boxSkeleton()
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let b = boxInstance(0, 0, 10, 10, skeleton: skel)
        XCTAssertEqual(a.boundingBoxIoU(with: b), 1.0, accuracy: 1e-6)
        XCTAssertTrue(a.overlapsWith(b))
    }

    func testIoUDisjointInstancesIsZero() {
        let skel = boxSkeleton()
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let c = boxInstance(20, 20, 30, 30, skeleton: skel)
        XCTAssertEqual(a.boundingBoxIoU(with: c), 0.0, accuracy: 1e-6)
        XCTAssertFalse(a.overlapsWith(c))
    }

    func testIoUTouchingEdgesIsZero() {
        // Boxes that share only an edge (x in [0,10] vs [10,20]) do not overlap.
        let skel = boxSkeleton()
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let b = boxInstance(10, 0, 20, 10, skeleton: skel)
        XCTAssertEqual(a.boundingBoxIoU(with: b), 0.0, accuracy: 1e-6)
        XCTAssertFalse(a.overlapsWith(b))
    }

    func testIoUPartialOverlapValue() {
        // A = [0,0]-[10,10] (area 100); B = [5,0]-[15,10] (area 100).
        // Intersection = [5,0]-[10,10] (area 50); union = 150; IoU = 1/3.
        let skel = boxSkeleton()
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let b = boxInstance(5, 0, 15, 10, skeleton: skel)
        XCTAssertEqual(a.boundingBoxIoU(with: b), 1.0 / 3.0, accuracy: 1e-6)
        // IoU ~0.333: below the 0.5 default, above a 0.3 threshold.
        XCTAssertFalse(a.overlapsWith(b))
        XCTAssertTrue(a.overlapsWith(b, iouThreshold: 0.3))
    }

    func testIoUHighOverlapExceedsDefaultThreshold() {
        // A = [0,0]-[10,10]; B = [1,1]-[11,11]. Intersection = [1,1]-[10,10]
        // (area 81); union = 119; IoU = 81/119 ~= 0.6807.
        let skel = boxSkeleton()
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let b = boxInstance(1, 1, 11, 11, skeleton: skel)
        XCTAssertEqual(a.boundingBoxIoU(with: b), 81.0 / 119.0, accuracy: 1e-6)
        XCTAssertTrue(a.overlapsWith(b))
    }

    func testIoUIsSymmetric() {
        let skel = boxSkeleton()
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let b = boxInstance(5, 0, 15, 10, skeleton: skel)
        XCTAssertEqual(a.boundingBoxIoU(with: b), b.boundingBoxIoU(with: a), accuracy: 1e-6)
    }

    func testIoUZeroWhenNoVisiblePoints() {
        let skel = boxSkeleton()
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let empty = Instance.empty(skeleton: skel)
        XCTAssertEqual(a.boundingBoxIoU(with: empty), 0.0, accuracy: 1e-6)
        XCTAssertFalse(a.overlapsWith(empty))
        XCTAssertFalse(empty.overlapsWith(a))
    }

    func testLegacyOverlapsStillAvailable() {
        // The coarse boolean intersection test is retained for source-compat.
        let skel = boxSkeleton()
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let b = boxInstance(5, 5, 15, 15, skeleton: skel)
        let c = boxInstance(20, 20, 30, 30, skeleton: skel)
        XCTAssertTrue(a.overlaps(with: b))
        XCTAssertFalse(a.overlaps(with: c))
    }

    // MARK: - samePoseAs

    func testSamePoseExactMatch() {
        let skel = pairSkeleton()
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)
        let b = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)
        XCTAssertTrue(a.samePoseAs(b))
        XCTAssertTrue(a.samePoseAs(b, tolerance: 0))
    }

    func testSamePoseExactMismatch() {
        let skel = pairSkeleton()
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)
        let b = Instance.from(numpy: [[0, 0], [10, 11]], skeleton: skel)
        XCTAssertFalse(a.samePoseAs(b))
    }

    func testSamePoseWithinTolerance() {
        // Node "a" differs by sqrt(2) ~= 1.414 pixels.
        let skel = pairSkeleton()
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)
        let b = Instance.from(numpy: [[1, 1], [10, 10]], skeleton: skel)
        XCTAssertTrue(a.samePoseAs(b, tolerance: 2.0))
    }

    func testSamePoseOutsideTolerance() {
        let skel = pairSkeleton()
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)
        let b = Instance.from(numpy: [[1, 1], [10, 10]], skeleton: skel)
        // sqrt(2) ~= 1.414 exceeds a 1.0 tolerance.
        XCTAssertFalse(a.samePoseAs(b, tolerance: 1.0))
    }

    func testSamePoseNaNPatternMustMatch() {
        // Same visible coordinates but different visibility patterns => no match,
        // regardless of tolerance.
        let skel = pairSkeleton()
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)
        let b = Instance.from(numpy: [[0, 0], [.nan, .nan]], skeleton: skel)
        XCTAssertFalse(a.samePoseAs(b))
        XCTAssertFalse(a.samePoseAs(b, tolerance: 100.0))
    }

    func testSamePoseAllInvisibleAreEqual() {
        let skel = pairSkeleton()
        let a = Instance.empty(skeleton: skel)
        let b = Instance.empty(skeleton: skel)
        XCTAssertTrue(a.samePoseAs(b))
        XCTAssertTrue(a.samePoseAs(b, tolerance: 1.0))
    }

    func testSamePoseIgnoresTrackIdentity() {
        // Pose equality does not depend on track assignment.
        let skel = pairSkeleton()
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel, track: Track(name: "t1"))
        let b = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel, track: Track(name: "t2"))
        XCTAssertTrue(a.samePoseAs(b))
    }

    func testSamePoseDifferentSkeletonNamesDoesNotMatch() {
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: pairSkeleton())
        let other = Skeleton(name: "other", nodes: ["x", "y", "z"].map { Node(name: $0) })
        let b = Instance.from(numpy: [[0, 0], [10, 10], [5, 5]], skeleton: other)
        XCTAssertFalse(a.samePoseAs(b))
    }

    // MARK: - sameIdentityAs

    func testSameIdentitySharedTrack() {
        let skel = pairSkeleton()
        let track = Track(name: "animal")
        let a = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel, track: track)
        let b = Instance.from(numpy: [[9, 9], [8, 8]], skeleton: skel, track: track)
        XCTAssertTrue(a.sameIdentityAs(b))
    }

    func testSameIdentityDifferentTrackObjectsSameName() {
        // Identity is by object, not by name.
        let skel = pairSkeleton()
        let a = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel, track: Track(name: "animal"))
        let b = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel, track: Track(name: "animal"))
        XCTAssertFalse(a.sameIdentityAs(b))
    }

    func testSameIdentityNilTracks() {
        let skel = pairSkeleton()
        let track = Track(name: "animal")
        let tracked = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel, track: track)
        let untracked = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel)
        let untracked2 = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel)
        XCTAssertFalse(tracked.sameIdentityAs(untracked))
        XCTAssertFalse(untracked.sameIdentityAs(tracked))
        XCTAssertFalse(untracked.sameIdentityAs(untracked2))
    }

    // MARK: - InstanceMatcher.match

    func testMatcherSpatial() {
        let skel = pairSkeleton()
        let matcher = InstanceMatcher(method: .spatial, threshold: 2.0)
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)
        let near = Instance.from(numpy: [[1, 1], [10, 10]], skeleton: skel)
        let far = Instance.from(numpy: [[50, 50], [60, 60]], skeleton: skel)
        XCTAssertTrue(matcher.match(a, near))
        XCTAssertFalse(matcher.match(a, far))
    }

    func testMatcherIdentity() {
        let skel = pairSkeleton()
        let matcher = InstanceMatcher(method: .identity)
        let track = Track(name: "animal")
        let a = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel, track: track)
        let b = Instance.from(numpy: [[9, 9], [8, 8]], skeleton: skel, track: track)
        let c = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel, track: Track(name: "other"))
        XCTAssertTrue(matcher.match(a, b))
        XCTAssertFalse(matcher.match(a, c))
    }

    func testMatcherIoU() {
        let skel = boxSkeleton()
        let matcher = InstanceMatcher(method: .iou, threshold: 0.5)
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let high = boxInstance(1, 1, 11, 11, skeleton: skel) // IoU ~0.68
        let low = boxInstance(5, 0, 15, 10, skeleton: skel)  // IoU ~0.33
        XCTAssertTrue(matcher.match(a, high))
        XCTAssertFalse(matcher.match(a, low))
    }

    // MARK: - InstanceMatcher.findMatches

    func testFindMatchesSpatialScoresRankCloserHigher() {
        let skel = pairSkeleton()
        let matcher = InstanceMatcher(method: .spatial, threshold: 5.0)
        let a = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)          // idx 0
        let b = Instance.from(numpy: [[100, 100], [110, 110]], skeleton: skel)    // idx 1
        let exact = Instance.from(numpy: [[0, 0], [10, 10]], skeleton: skel)      // idx 0
        let near = Instance.from(numpy: [[1, 0], [10, 10]], skeleton: skel)       // idx 1

        let matches = matcher.findMatches([a, b], [exact, near])
        // a matches both exact (score 1.0) and near; b matches neither.
        let aMatches = matches.filter { $0.index1 == 0 }
        XCTAssertEqual(Set(aMatches.map { $0.index2 }), [0, 1])
        XCTAssertTrue(matches.allSatisfy { $0.index1 != 1 }, "Far instance should not match")

        let exactScore = matches.first { $0.index1 == 0 && $0.index2 == 0 }?.score
        let nearScore = matches.first { $0.index1 == 0 && $0.index2 == 1 }?.score
        XCTAssertEqual(exactScore ?? 0, 1.0, accuracy: 1e-6)
        XCTAssertNotNil(nearScore)
        XCTAssertLessThan(nearScore ?? 1.0, 1.0)
    }

    func testFindMatchesIoUScoresAreActualIoU() {
        let skel = boxSkeleton()
        let matcher = InstanceMatcher(method: .iou, threshold: 0.1)
        let a = boxInstance(0, 0, 10, 10, skeleton: skel)
        let b = boxInstance(5, 0, 15, 10, skeleton: skel) // IoU = 1/3
        let matches = matcher.findMatches([a], [b])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].score, 1.0 / 3.0, accuracy: 1e-6)
    }

    func testFindMatchesIdentityScoresAreOne() {
        let skel = pairSkeleton()
        let matcher = InstanceMatcher(method: .identity)
        let track = Track(name: "animal")
        let a = Instance.from(numpy: [[0, 0], [1, 1]], skeleton: skel, track: track)
        let b = Instance.from(numpy: [[9, 9], [8, 8]], skeleton: skel, track: track)
        let matches = matcher.findMatches([a], [b])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].score, 1.0, accuracy: 1e-6)
    }

    // MARK: - Configuration

    func testDefaultMatcherIsSpatialWithFiveThreshold() {
        let matcher = InstanceMatcher()
        XCTAssertEqual(matcher.method, .spatial)
        XCTAssertEqual(matcher.threshold, 5.0)
    }

    func testPreconfiguredMatchers() {
        XCTAssertEqual(InstanceMatcher.duplicate, InstanceMatcher(method: .spatial, threshold: 5.0))
        XCTAssertEqual(InstanceMatcher.iou, InstanceMatcher(method: .iou, threshold: 0.5))
        XCTAssertEqual(InstanceMatcher.identity.method, .identity)
    }
}
