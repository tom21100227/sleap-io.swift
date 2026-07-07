import XCTest
@testable import SleapIO
@testable import SleapHDF5

final class ProgressCancellationTests: XCTestCase {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []

        func append(_ value: Double) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var values: [Double] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_progress_\(UUID().uuidString).slp")
    }

    private func makeLabels(frameCount: Int = 8) -> Labels {
        let skeleton = Skeleton(name: "animal", nodes: [Node(name: "head"), Node(name: "tail")])
        let video = Video(filename: "progress.mp4")
        let frames = (0..<frameCount).map { index in
            LabeledFrame(
                video: video,
                frameIndex: index,
                instances: [Instance(skeleton: skeleton)]
            )
        }
        return Labels(
            frameStore: EagerFrameStore(frames: frames),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )
    }

    func testSaveProgressIsMonotonicEndsAtOneAndRoundTrips() async throws {
        let labels = makeLabels()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = ProgressRecorder()
        try await labels.save(to: url, progress: { recorder.append($0) })

        let values = recorder.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last, 1.0)
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })

        let reloaded = try await Labels.loadEager(from: url)
        XCTAssertEqual(reloaded.frameCount, labels.frameCount)
        XCTAssertEqual(reloaded.skeletons.map(\.nodeNames), labels.skeletons.map(\.nodeNames))
    }

    func testSaveCancellationIsTolerant() async throws {
        let labels = makeLabels(frameCount: 64)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task {
            try await labels.save(to: url, progress: { _ in })
        }
        task.cancel()

        do {
            try await task.value
        } catch is CancellationError {
            return
        }
    }
}
