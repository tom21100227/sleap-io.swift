import XCTest
@testable import SleapIO

/// E1.1: O(1) cached frame lookup in `Labels.frame(for:at:)`.
final class LabelsFrameIndexTests: XCTestCase {

    private let skel = Skeleton(name: "s", nodes: [Node(name: "a")])

    private func makeLabels() throws -> (Labels, Video, Video) {
        let v1 = Video(filename: "v1.mp4")
        let v2 = Video(filename: "v2.mp4")
        let labels = Labels()
        for idx in [0, 5, 10] { try labels.addFrame(LabeledFrame(video: v1, frameIndex: idx)) }
        for idx in [0, 7] { try labels.addFrame(LabeledFrame(video: v2, frameIndex: idx)) }
        return (labels, v1, v2)
    }

    /// Brute-force reference matching the previous linear-scan semantics.
    private func linearScan(_ labels: Labels, _ video: Video, _ frameIndex: Int) -> LabeledFrame? {
        for f in labels where f.video === video && f.frameIndex == frameIndex { return f }
        return nil
    }

    func testMatchesLinearScan() throws {
        let (labels, v1, v2) = try makeLabels()
        for (v, idxs) in [(v1, [0, 5, 10, 3]), (v2, [0, 7, 1])] {
            for idx in idxs {
                XCTAssertTrue(labels.frame(for: v, at: idx) === linearScan(labels, v, idx),
                              "mismatch for frame \(idx)")
            }
        }
    }

    func testReturnsNilForMissing() throws {
        let (labels, v1, _) = try makeLabels()
        XCTAssertNil(labels.frame(for: v1, at: 999))
    }

    func testCrossVideoIsolation() throws {
        let (labels, v1, v2) = try makeLabels()
        // v2 has frame 7; v1 does not.
        XCTAssertNotNil(labels.frame(for: v2, at: 7))
        XCTAssertNil(labels.frame(for: v1, at: 7))
    }

    func testInvalidatesOnAdd() throws {
        let (labels, v1, _) = try makeLabels()
        XCTAssertNil(labels.frame(for: v1, at: 42)) // primes the cache
        let f = LabeledFrame(video: v1, frameIndex: 42)
        try labels.addFrame(f)
        XCTAssertTrue(labels.frame(for: v1, at: 42) === f, "new frame must be found after add")
    }

    func testInvalidatesOnRemove() throws {
        let (labels, v1, _) = try makeLabels()
        let f = labels.frame(for: v1, at: 5)!
        try labels.removeFrame(f)
        XCTAssertNil(labels.frame(for: v1, at: 5), "removed frame must not be found")
        XCTAssertNotNil(labels.frame(for: v1, at: 10), "other frames still found")
    }

    func testForeignVideoObjectReturnsNil() throws {
        let (labels, _, _) = try makeLabels()
        let foreign = Video(filename: "v1.mp4") // same path, different identity
        XCTAssertNil(labels.frame(for: foreign, at: 0),
                     "foreign Video object is not resolved (identity semantics; see E1.2)")
    }

    func testRepeatedLookupsConsistent() throws {
        let (labels, v1, _) = try makeLabels()
        let a = labels.frame(for: v1, at: 10)
        let b = labels.frame(for: v1, at: 10)
        XCTAssertTrue(a === b)
    }
}
