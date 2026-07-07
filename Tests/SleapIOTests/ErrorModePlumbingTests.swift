import XCTest
@testable import SleapIO

final class ErrorModePlumbingTests: XCTestCase {
    private func skeleton(_ name: String, _ nodeNames: [String]) -> Skeleton {
        Skeleton(name: name, nodes: nodeNames.map(Node.init(name:)))
    }

    private func labels(skeletons: [Skeleton], frameSkeleton: Skeleton? = nil) -> Labels {
        let video = Video(filename: "\(UUID().uuidString).mp4")
        let frames: [LabeledFrame]
        if let frameSkeleton {
            frames = [
                LabeledFrame(
                    video: video,
                    frameIndex: 0,
                    instances: [Instance(skeleton: frameSkeleton)]
                ),
            ]
        } else {
            frames = []
        }
        return Labels(
            frameStore: EagerFrameStore(frames: frames),
            videos: [video],
            skeletons: skeletons,
            tracks: []
        )
    }

    func testStrictThrowsSkeletonMismatchBeforeMutating() throws {
        let local = skeleton("local", ["head", "thorax"])
        let incoming = skeleton("incoming", ["head", "abdomen"])
        let base = labels(skeletons: [local])
        let other = labels(skeletons: [incoming], frameSkeleton: incoming)

        XCTAssertThrowsError(try base.merge(from: other, errorMode: .strict)) { error in
            XCTAssertEqual(
                error as? RecoverableSleapError,
                .skeletonMismatch(expected: ["head", "thorax"], found: ["head", "abdomen"])
            )
        }
        XCTAssertEqual(base.skeletons.count, 1)
        XCTAssertEqual(base.frameCount, 0)
    }

    func testWarnCollectsErrorsAndMerges() throws {
        let local = skeleton("local", ["head", "thorax"])
        let incoming = skeleton("incoming", ["head", "abdomen"])
        let base = labels(skeletons: [local])
        let other = labels(skeletons: [incoming], frameSkeleton: incoming)

        let result = try base.merge(from: other, errorMode: .warn)

        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(result.successful)
        // Incoming skeleton does not match local, so it is appended (not deduped).
        XCTAssertEqual(base.skeletons.count, 2)
        XCTAssertEqual(base.frameCount, 1)
    }

    func testIgnoreMergesSilently() throws {
        let local = skeleton("local", ["head", "thorax"])
        let incoming = skeleton("incoming", ["head", "abdomen"])
        let base = labels(skeletons: [local])
        let other = labels(skeletons: [incoming], frameSkeleton: incoming)

        let result = try base.merge(from: other)

        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(result.successful)
        XCTAssertEqual(base.skeletons.count, 2)
        XCTAssertEqual(base.frameCount, 1)
    }

    func testStrictMergeIntoEmptyLabelsAcceptsFirstSkeleton() throws {
        let incoming = skeleton("incoming", ["head", "abdomen"])
        let base = Labels()
        let other = labels(skeletons: [incoming], frameSkeleton: incoming)

        let result = try base.merge(from: other, errorMode: .strict)

        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(result.successful)
        XCTAssertEqual(base.skeletons.count, 1)
        XCTAssertEqual(base.frameCount, 1)
    }

    func testCompatibleSkeletonsDedupAndReturnNoErrorsInAllModes() throws {
        for mode in [ErrorMode.strict, .warn, .ignore] {
            let local = skeleton("local", ["head", "thorax"])
            let incoming = skeleton("incoming", ["thorax", "head"])
            let base = labels(skeletons: [local])
            let other = labels(skeletons: [incoming], frameSkeleton: incoming)

            let result = try base.merge(from: other, errorMode: mode)

            XCTAssertEqual(result.errors, [])
            XCTAssertTrue(result.successful)
            // Matcher-driven dedup: incoming matches local structurally, so it is
            // reused rather than appended.
            XCTAssertEqual(base.skeletons.count, 1)
            XCTAssertEqual(base.frameCount, 1)
        }
    }

    func testAnyMatchingLocalSkeletonAvoidsPartialOverlapFalsePositive() throws {
        let partialOverlap = skeleton("partial", ["head", "thorax"])
        let exactMatch = skeleton("exact", ["head", "abdomen"])
        let incoming = skeleton("incoming", ["abdomen", "head"])
        let base = labels(skeletons: [partialOverlap, exactMatch])
        let other = labels(skeletons: [incoming], frameSkeleton: incoming)

        let result = try base.merge(from: other, errorMode: .strict)

        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(result.successful)
        // Incoming matches the exact-match skeleton, so it is deduped onto it.
        XCTAssertEqual(base.skeletons.count, 2)
        XCTAssertEqual(base.frameCount, 1)
    }
}
