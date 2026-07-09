import XCTest
@testable import SleapIO

/// E4.6: snapshot-isolation contract — copy() enables safe background handoff.
final class ConcurrencyContractTests: XCTestCase {

    private func makeLabels() throws -> Labels {
        let skel = Skeleton(name: "s", nodes: [Node(name: "a")])
        let video = Video(filename: "v.mp4")
        let labels = Labels()
        for i in 0..<3 {
            let f = LabeledFrame(video: video, frameIndex: i)
            f.instances.append(Instance(skeleton: skel))
            try labels.addFrame(f)
        }
        return labels
    }

    func testCopyEnablesSafeBackgroundHandoff() async throws {
        let labels = try makeLabels()
        let originalInstances = labels.instanceCount
        let snapshot = labels.copy()

        // Read the snapshot on a detached task while mutating the original here.
        async let bgCount: Int = Task.detached { () -> Int in
            var sum = 0
            for f in snapshot { sum += f.instances.count }
            return sum
        }.value

        // Mutate the original concurrently (snapshot must be unaffected).
        let skel = labels.skeletons[0]
        let extra = LabeledFrame(video: labels.videos[0], frameIndex: 99)
        extra.instances.append(Instance(skeleton: skel))
        try labels.addFrame(extra)

        let counted = await bgCount
        XCTAssertEqual(counted, originalInstances, "snapshot is independent of later original mutations")
        XCTAssertEqual(snapshot.frameCount, 3, "snapshot frame count unchanged")
        XCTAssertEqual(labels.frameCount, 4, "original grew")
    }

    func testSnapshotSummaryConstant() {
        XCTAssertFalse(ConcurrencyContract.safeHandoffSummary.isEmpty)
    }
}
