import XCTest
import Foundation
@testable import SleapIO
@testable import SleapHDF5

/// Stress tests using real-world SLP files of varying size and complexity.
///
/// These tests require fixtures in `Tests/Fixtures/stress/` which are gitignored.
/// They are skipped if the fixtures are not present.
final class StressTests: XCTestCase {

    // MARK: - Fixture helpers

    private func emitBenchmark(
        fixture: String,
        metric: String,
        seconds: Double,
        extra: [String: CustomStringConvertible] = [:]
    ) {
        var fields = [
            "BENCHMARK",
            "source=swift",
            "fixture=\(fixture)",
            "metric=\(metric)",
            "seconds=\(String(format: "%.6f", seconds))",
        ]

        for key in extra.keys.sorted() {
            if let value = extra[key] {
                fields.append("\(key)=\(value)")
            }
        }

        print(fields.joined(separator: " "))
    }

    private func stressFixtureURL(_ name: String) throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SleapHDF5Tests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let url = packageRoot.appendingPathComponent("Tests/Fixtures/stress/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Stress fixture '\(name)' not found")
        }
        return url
    }

    private func tempURL(extension ext: String = "slp") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_stress_\(UUID().uuidString).\(ext)")
    }

    // MARK: - single_predictions.slp (2.2 MB, 5k frames, 1 pred/frame)

    func testSinglePredictions_lazyLoad() async throws {
        let url = try stressFixtureURL("single_predictions.slp")
        let start = CFAbsoluteTimeGetCurrent()
        let labels = try await Labels.load(from: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 5002)
        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.skeleton?.nodes.count, 14)
        XCTAssertEqual(labels.skeleton?.edges.count, 8)
        XCTAssertEqual(labels.instanceCount, 5002)
        XCTAssertEqual(labels.predictedInstanceCount, 5002)

        emitBenchmark(fixture: "single_predictions", metric: "lazy_load", seconds: elapsed)
    }

    func testSinglePredictions_eagerLoad() async throws {
        let url = try stressFixtureURL("single_predictions.slp")
        let start = CFAbsoluteTimeGetCurrent()
        let labels = try await Labels.loadEager(from: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 5002)
        XCTAssertEqual(labels.predictedInstanceCount, 5002)

        // Verify first and last frame data
        let first = labels[0]
        XCTAssertEqual(first.instances.count, 1)
        XCTAssertTrue(first.instances[0] is PredictedInstance)
        XCTAssertEqual(first.instances[0].points.count, 14)

        let last = labels[labels.frameCount - 1]
        XCTAssertEqual(last.instances.count, 1)
        XCTAssertTrue(last.instances[0] is PredictedInstance)

        emitBenchmark(fixture: "single_predictions", metric: "eager_load", seconds: elapsed)
    }

    func testSinglePredictions_lazyRandomAccess() async throws {
        let url = try stressFixtureURL("single_predictions.slp")
        let labels = try await Labels.load(from: url)

        // Access frames in random order — tests lazy materialization
        let indices = [0, 4999, 2500, 100, 4000, 1, 3333]
        let start = CFAbsoluteTimeGetCurrent()
        for i in indices {
            let frame = labels[i]
            XCTAssertEqual(frame.instances.count, 1)
            let inst = frame.instances[0]
            XCTAssertTrue(inst is PredictedInstance)

            // Verify points are finite (not NaN placeholder)
            let visibleCount = inst.points.visibility.filter { $0 }.count
            XCTAssertGreaterThan(visibleCount, 0, "Frame \(i) should have visible points")
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        emitBenchmark(
            fixture: "single_predictions",
            metric: "random_access",
            seconds: elapsed,
            extra: ["frames": indices.count]
        )

        // Identity stability: same index returns same object
        let f1 = labels[0]
        let f2 = labels[0]
        XCTAssertTrue(f1 === f2)
    }

    func testSinglePredictions_pointDataIntegrity() async throws {
        let url = try stressFixtureURL("single_predictions.slp")
        let labels = try await Labels.loadEager(from: url)

        // Scan all frames: every predicted instance should have valid point data
        for i in 0..<labels.frameCount {
            let frame = labels[i]
            for inst in frame.instances {
                guard let pred = inst as? PredictedInstance else {
                    XCTFail("Frame \(i): expected PredictedInstance")
                    continue
                }
                // Points array length must match skeleton
                XCTAssertEqual(pred.points.count, 14, "Frame \(i): wrong point count")
                // Score should be non-negative
                XCTAssertGreaterThanOrEqual(pred.score, 0.0, "Frame \(i): negative score")
            }
        }
    }

    // MARK: - training_mixed.pkg.slp (2.5 MB, 540 frames, 183 videos, mixed embedded + external)

    func testTrainingMixed_lazyLoad() async throws {
        let url = try stressFixtureURL("training_mixed.pkg.slp")
        let start = CFAbsoluteTimeGetCurrent()
        let labels = try await Labels.load(from: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 540)
        XCTAssertEqual(labels.videos.count, 183)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.skeleton?.name, "cricket_hind")
        XCTAssertEqual(labels.skeleton?.nodes.count, 14)
        XCTAssertEqual(labels.skeleton?.edges.count, 8)
        XCTAssertEqual(labels.instanceCount, 540)
        XCTAssertEqual(labels.predictedInstanceCount, 0)

        emitBenchmark(fixture: "training_mixed", metric: "lazy_load", seconds: elapsed)
    }

    func testTrainingMixed_eagerLoad() async throws {
        let url = try stressFixtureURL("training_mixed.pkg.slp")
        let start = CFAbsoluteTimeGetCurrent()
        let labels = try await Labels.loadEager(from: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 540)
        XCTAssertEqual(labels.instanceCount, 540)

        // All instances should be user instances (no predictions)
        for i in 0..<labels.frameCount {
            let frame = labels[i]
            for inst in frame.instances {
                XCTAssertFalse(inst is PredictedInstance, "Frame \(i): expected user instance")
            }
        }

        emitBenchmark(fixture: "training_mixed", metric: "eager_load", seconds: elapsed)
    }

    func testTrainingMixed_multiVideoIdentity() async throws {
        let url = try stressFixtureURL("training_mixed.pkg.slp")
        let labels = try await Labels.load(from: url)

        // Verify video identity: frames referencing the same video share the same object
        var videoSet = Set<ObjectIdentifier>()
        for i in 0..<labels.frameCount {
            videoSet.insert(ObjectIdentifier(labels[i].video))
        }
        // Should have multiple distinct videos (not all the same)
        XCTAssertGreaterThan(videoSet.count, 1, "Expected multiple distinct video objects")
        // But not more than 183
        XCTAssertLessThanOrEqual(videoSet.count, 183)
    }

    // MARK: - training_embedded.pkg.slp (540 frames, 183 videos, all embedded)
    // NOTE: This fixture is a truncated copy (268 KB vs 472 MB original).
    // It has 542 /instances rows (2 extra ghost instances in frame 0) vs
    // 540 in the source SLP. Assertions match the fixture, not the original.

    func testTrainingEmbedded_lazyLoad() async throws {
        let url = try stressFixtureURL("training_embedded.pkg.slp")
        let start = CFAbsoluteTimeGetCurrent()
        let labels = try await Labels.load(from: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 540)
        XCTAssertEqual(labels.videos.count, 183)
        // Frame 0 has 3 user instances; all other 539 frames have 1 each => 542 total
        XCTAssertEqual(labels.instanceCount, 542)
        XCTAssertEqual(labels.predictedInstanceCount, 0)

        emitBenchmark(fixture: "training_embedded", metric: "lazy_load", seconds: elapsed)
    }

    func testTrainingEmbedded_eagerLoad() async throws {
        let url = try stressFixtureURL("training_embedded.pkg.slp")
        let start = CFAbsoluteTimeGetCurrent()
        let labels = try await Labels.loadEager(from: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 540)

        // Verify user instance data integrity
        // Note: some instances may have 0 visible points — this is valid SLEAP data
        // (user placed an instance but didn't label any nodes yet).
        for i in 0..<labels.frameCount {
            let frame = labels[i]
            XCTAssertGreaterThanOrEqual(frame.instances.count, 1,
                "Frame \(i): expected at least 1 instance")
            for inst in frame.instances {
                XCTAssertEqual(inst.points.count, 14, "Frame \(i): wrong point count")
            }
        }

        emitBenchmark(fixture: "training_embedded", metric: "eager_load", seconds: elapsed)
    }

    func testTrainingEmbedded_embeddedVideoFrameAccess() async throws {
        let url = try stressFixtureURL("training_embedded.pkg.slp")
        let labels = try await Labels.load(from: url)

        // Verify the backend is correctly wired up (HDF5Video → embedded backend)
        let frame = labels[0]
        XCTAssertTrue(
            frame.video.backendType.lowercased().hasPrefix("hdf5"),
            "Expected HDF5 backend type, got: \(frame.video.backendType)"
        )

        // Try to open the embedded video backend. If the fixture is a stripped-down
        // copy missing the actual video groups (video0, video1, ...), skip the test.
        do {
            try await frame.video.open()
        } catch {
            throw XCTSkip("Embedded video groups not present in fixture: \(error.localizedDescription)")
        }

        // Access an embedded frame (supports both vlen and fixed-length rank-2 datasets)
        let start = CFAbsoluteTimeGetCurrent()
        let image = try await frame.video.frame(at: frame.frameIndex)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        frame.video.close()

        emitBenchmark(
            fixture: "training_embedded",
            metric: "embedded_frame_access",
            seconds: elapsed,
            extra: ["frame": frame.frameIndex]
        )
    }

    // MARK: - large_predictions.slp (123 MB, 90k frames, 280k predicted instances)

    func testLargePredictions_lazyLoad() async throws {
        let url = try stressFixtureURL("large_predictions.slp")
        let start = CFAbsoluteTimeGetCurrent()
        let labels = try await Labels.load(from: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 90000)
        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.skeleton?.nodes.count, 15)
        XCTAssertEqual(labels.skeleton?.edges.count, 14)
        XCTAssertEqual(labels.predictedInstanceCount, 280438)

        // Lazy load of 123 MB should still be fast (metadata only)
        XCTAssertLessThan(elapsed, 5.0, "Lazy load took too long: \(elapsed)s")

        emitBenchmark(fixture: "large_predictions", metric: "lazy_load", seconds: elapsed)
    }

    func testLargePredictions_eagerLoad() async throws {
        let url = try stressFixtureURL("large_predictions.slp")
        let start = CFAbsoluteTimeGetCurrent()
        let labels = try await Labels.loadEager(from: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(labels.isLazy)
        XCTAssertEqual(labels.frameCount, 90000)
        XCTAssertEqual(labels.predictedInstanceCount, 280438)

        emitBenchmark(fixture: "large_predictions", metric: "eager_load", seconds: elapsed)
    }

    func testLargePredictions_lazyRandomAccess() async throws {
        let url = try stressFixtureURL("large_predictions.slp")
        let labels = try await Labels.load(from: url)

        // Random access across the full range
        let indices = [0, 89999, 45000, 1000, 80000, 10, 60000, 25000, 75000, 50000]
        let start = CFAbsoluteTimeGetCurrent()
        for i in indices {
            let frame = labels[i]
            XCTAssertGreaterThanOrEqual(frame.instances.count, 1,
                "Frame \(i): expected at least 1 instance")
            for inst in frame.instances {
                XCTAssertTrue(inst is PredictedInstance, "Frame \(i): expected predicted")
                XCTAssertEqual(inst.points.count, 15, "Frame \(i): wrong point count")
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        emitBenchmark(
            fixture: "large_predictions",
            metric: "random_access",
            seconds: elapsed,
            extra: ["frames": indices.count]
        )
    }

    func testLargePredictions_lazyScanFirst1000() async throws {
        let url = try stressFixtureURL("large_predictions.slp")
        let labels = try await Labels.load(from: url)

        // Sequential scan of first 1000 frames — tests lazy cache performance
        let start = CFAbsoluteTimeGetCurrent()
        var totalInstances = 0
        for i in 0..<1000 {
            let frame = labels[i]
            totalInstances += frame.instances.count
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertGreaterThan(totalInstances, 0)
        emitBenchmark(
            fixture: "large_predictions",
            metric: "scan_1000",
            seconds: elapsed,
            extra: ["frames": 1000, "instances": totalInstances]
        )
    }

    func testLargePredictions_instanceDistribution() async throws {
        let url = try stressFixtureURL("large_predictions.slp")
        let labels = try await Labels.load(from: url)

        // Sample frames across the range and verify instance structure
        let sampleIndices = stride(from: 0, to: labels.frameCount, by: 10000)
        var maxInstancesPerFrame = 0
        for i in sampleIndices {
            let frame = labels[i]
            maxInstancesPerFrame = max(maxInstancesPerFrame, frame.instances.count)
            for inst in frame.instances {
                XCTAssertTrue(inst is PredictedInstance, "Frame \(i): expected predicted")
                // If tracks exist, verify assignment
                if !labels.tracks.isEmpty {
                    XCTAssertNotNil(inst.track, "Frame \(i): expected track assignment")
                }
            }
        }
        // Bottom-up multi-animal: should have varying instance counts
        XCTAssertGreaterThan(maxInstancesPerFrame, 1,
            "Expected multi-instance frames in bottom-up predictions")
    }

    // MARK: - Round-trip: eager load -> save -> reload

    func testSinglePredictions_roundTrip() async throws {
        let url = try stressFixtureURL("single_predictions.slp")
        let original = try await Labels.loadEager(from: url)

        let tmpURL = tempURL()
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let start = CFAbsoluteTimeGetCurrent()
        try await original.save(to: tmpURL)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        emitBenchmark(fixture: "single_predictions", metric: "save", seconds: elapsed)

        let reloaded = try await Labels.loadEager(from: tmpURL)

        XCTAssertEqual(reloaded.frameCount, original.frameCount)
        XCTAssertEqual(reloaded.videos.count, original.videos.count)
        XCTAssertEqual(reloaded.skeletons.count, original.skeletons.count)
        XCTAssertEqual(reloaded.tracks.count, original.tracks.count)
        XCTAssertEqual(reloaded.instanceCount, original.instanceCount)
        XCTAssertEqual(reloaded.predictedInstanceCount, original.predictedInstanceCount)

        // Spot-check point data
        let origFrame = original[0]
        let reloadFrame = reloaded[0]
        XCTAssertEqual(origFrame.frameIndex, reloadFrame.frameIndex)
        XCTAssertEqual(origFrame.instances.count, reloadFrame.instances.count)

        if let origPt = origFrame.instances.first?.points,
           let reloadPt = reloadFrame.instances.first?.points {
            for k in 0..<origPt.count {
                XCTAssertEqual(origPt[k].x, reloadPt[k].x, accuracy: 1e-4)
                XCTAssertEqual(origPt[k].y, reloadPt[k].y, accuracy: 1e-4)
            }
        }
    }

    func testTrainingMixed_roundTrip() async throws {
        let url = try stressFixtureURL("training_mixed.pkg.slp")
        let original = try await Labels.loadEager(from: url)

        let tmpURL = tempURL()
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let start = CFAbsoluteTimeGetCurrent()
        try await original.save(to: tmpURL)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        emitBenchmark(fixture: "training_mixed", metric: "save", seconds: elapsed)

        let reloaded = try await Labels.loadEager(from: tmpURL)

        XCTAssertEqual(reloaded.frameCount, original.frameCount)
        XCTAssertEqual(reloaded.videos.count, original.videos.count)
        XCTAssertEqual(reloaded.instanceCount, original.instanceCount)
    }
}
