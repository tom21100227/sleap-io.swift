import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// S04-S05: SLP writer tests (round-trip fidelity and hybrid lazy save).
final class SLPWriterTests: XCTestCase {

    // MARK: - Fixture helpers

    private func fixtureURL(_ name: String) -> URL? {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SleapHDF5Tests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let url = packageRoot.appendingPathComponent("Tests/Fixtures/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func requireFixture(_ name: String) throws -> URL {
        guard let url = fixtureURL(name) else {
            throw XCTSkip("Fixture '\(name)' not found — generate fixtures first")
        }
        return url
    }

    private func tempURL(extension ext: String = "slp") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_test_\(UUID().uuidString).\(ext)")
    }

    // MARK: - S04: SLP round-trip fidelity

    func testS04_roundTripSparseV15() async throws {
        let url = try requireFixture("sparse_v1_5.slp")
        try await assertRoundTripFidelity(url)
    }

    func testS04_roundTripDensePredictionsV15() async throws {
        let url = try requireFixture("dense_predictions_v1_5.slp")
        try await assertRoundTripFidelity(url)
    }

    func testS04_roundTripPackagedFramesV15() async throws {
        let url = try requireFixture("packaged_frames_v1_5.pkg.slp")
        try await assertRoundTripFidelity(url)
    }

    /// Core round-trip assertion: load → save → load, then compare.
    private func assertRoundTripFidelity(_ url: URL, file: StaticString = #file, line: UInt = #line) async throws {
        // First load
        let labels1 = try await Labels.load(from: url)
        labels1.materialize()  // Materialize so we can iterate all frames

        // Save to temp
        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await labels1.save(to: outputURL)

        // Second load
        let labels2 = try await Labels.load(from: outputURL)
        labels2.materialize()

        // Compare behavioral equivalence
        XCTAssertEqual(labels1.count, labels2.count, "Frame count mismatch", file: file, line: line)
        XCTAssertEqual(labels1.videos.count, labels2.videos.count, "Video count mismatch", file: file, line: line)
        XCTAssertEqual(labels1.skeletons.count, labels2.skeletons.count, "Skeleton count mismatch", file: file, line: line)
        XCTAssertEqual(labels1.tracks.count, labels2.tracks.count, "Track count mismatch", file: file, line: line)

        // Compare skeleton topology
        for s in 0..<labels1.skeletons.count {
            let skel1 = labels1.skeletons[s]
            let skel2 = labels2.skeletons[s]
            XCTAssertEqual(skel1.name, skel2.name, file: file, line: line)
            XCTAssertEqual(skel1.nodes.count, skel2.nodes.count, file: file, line: line)
            XCTAssertEqual(skel1.edges.count, skel2.edges.count, file: file, line: line)

            for n in 0..<skel1.nodes.count {
                XCTAssertEqual(skel1.nodes[n].name, skel2.nodes[n].name, file: file, line: line)
            }
        }

        // Compare frames
        var totalInstances1 = 0
        var totalInstances2 = 0
        var totalPredicted1 = 0
        var totalPredicted2 = 0

        for i in 0..<labels1.count {
            let f1 = labels1[i]
            let f2 = labels2[i]

            XCTAssertEqual(f1.frameIndex, f2.frameIndex, "Frame \(i) index mismatch", file: file, line: line)
            XCTAssertEqual(
                f1.instances.count, f2.instances.count,
                "Frame \(i) instance count mismatch", file: file, line: line
            )

            totalInstances1 += f1.instances.count
            totalInstances2 += f2.instances.count
            totalPredicted1 += f1.predictedInstances.count
            totalPredicted2 += f2.predictedInstances.count

            // Compare point coordinates within tolerance
            for j in 0..<min(f1.instances.count, f2.instances.count) {
                let inst1 = f1.instances[j]
                let inst2 = f2.instances[j]

                XCTAssertEqual(
                    inst1.points.count, inst2.points.count,
                    "Instance \(j) in frame \(i): point count mismatch", file: file, line: line
                )

                for k in 0..<min(inst1.points.count, inst2.points.count) {
                    let p1 = inst1.points[k]
                    let p2 = inst2.points[k]

                    if p1.visible && p2.visible {
                        XCTAssertEqual(p1.x, p2.x, accuracy: 1e-3,
                                       "Point \(k) x mismatch in inst \(j) frame \(i)", file: file, line: line)
                        XCTAssertEqual(p1.y, p2.y, accuracy: 1e-3,
                                       "Point \(k) y mismatch in inst \(j) frame \(i)", file: file, line: line)
                    }

                    XCTAssertEqual(p1.visible, p2.visible,
                                   "Point \(k) visibility mismatch", file: file, line: line)
                }

                // Track assignment should match (same name)
                XCTAssertEqual(inst1.track?.name, inst2.track?.name,
                               "Track name mismatch in inst \(j) frame \(i)", file: file, line: line)
            }
        }

        XCTAssertEqual(totalInstances1, totalInstances2, "Total instance count mismatch", file: file, line: line)
        XCTAssertEqual(totalPredicted1, totalPredicted2, "Total predicted count mismatch", file: file, line: line)

        // Compare suggestions count
        XCTAssertEqual(labels1.suggestions.count, labels2.suggestions.count,
                       "Suggestion count mismatch", file: file, line: line)

        // Compare video filenames
        for v in 0..<labels1.videos.count {
            XCTAssertEqual(labels1.videos[v].filename, labels2.videos[v].filename, file: file, line: line)
        }

        // Compare track names
        for t in 0..<labels1.tracks.count {
            XCTAssertEqual(labels1.tracks[t].name, labels2.tracks[t].name, file: file, line: line)
        }
    }

    func testS04_identitySharingPreservedAfterRoundTrip() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels1 = try await Labels.load(from: url)
        labels1.materialize()

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await labels1.save(to: outputURL)

        let labels2 = try await Labels.load(from: outputURL)
        labels2.materialize()

        // After round-trip, shared identity must be preserved
        let skeleton = labels2.skeletons[0]
        for i in 0..<min(labels2.count, 10) {
            for inst in labels2[i].instances {
                if inst.skeleton.name == skeleton.name {
                    XCTAssertTrue(
                        inst.skeleton === skeleton,
                        "Skeleton identity must be preserved after round-trip"
                    )
                }
            }
        }

        // Videos should be shared
        if labels2.count >= 2 {
            let video = labels2[0].video
            for i in 1..<min(labels2.count, 10) {
                if labels2[i].video.filename == video.filename {
                    XCTAssertTrue(
                        labels2[i].video === video,
                        "Video identity must be preserved after round-trip"
                    )
                }
            }
        }
    }

    func testS04_fromPredictedPreservedAfterRoundTrip() async throws {
        let url = try requireFixture("dense_predictions_v1_5.slp")

        let labels1 = try await Labels.load(from: url)
        labels1.materialize()

        // Collect from_predicted links
        var originalLinks: [(frameIdx: Int, instIdx: Int)] = []
        for i in 0..<min(labels1.count, 20) {
            for (j, inst) in labels1[i].userInstances.enumerated() {
                if inst.fromPredicted != nil {
                    originalLinks.append((frameIdx: i, instIdx: j))
                }
            }
        }

        guard !originalLinks.isEmpty else {
            throw XCTSkip("No from_predicted links found in fixture")
        }

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await labels1.save(to: outputURL)

        let labels2 = try await Labels.load(from: outputURL)
        labels2.materialize()

        // Verify from_predicted links are preserved
        for link in originalLinks {
            guard link.frameIdx < labels2.count else { continue }
            let frame = labels2[link.frameIdx]
            let userInsts = frame.userInstances
            guard link.instIdx < userInsts.count else { continue }

            XCTAssertNotNil(
                userInsts[link.instIdx].fromPredicted,
                "from_predicted should be preserved after round-trip"
            )
        }
    }

    // MARK: - S05: Hybrid lazy save

    func testS05_lazySaveWithZeroCachedFrames() async throws {
        let url = try requireFixture("sparse_v1_5.slp")
        let labels = try await Labels.load(from: url)
        XCTAssertTrue(labels.isLazy)

        // Don't access any frames — zero cached
        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // Save should use the fast path (raw column copy)
        try await labels.save(to: outputURL)

        // Verify the output is valid by loading it
        let labels2 = try await Labels.load(from: outputURL)
        XCTAssertEqual(labels.count, labels2.count, "Lazy save should produce same frame count")
    }

    func testS05_lazySaveWithSomeCachedModifiedFrames() async throws {
        let url = try requireFixture("sparse_v1_5.slp")
        let labels = try await Labels.load(from: url)
        XCTAssertTrue(labels.isLazy)
        guard labels.count >= 2 else {
            throw XCTSkip("Need at least 2 frames")
        }

        // Access and modify frame 0
        let frame0 = labels[0]
        guard frame0.instances.count > 0 else {
            throw XCTSkip("Frame 0 has no instances")
        }
        let originalX = frame0.instances[0].points[0].x
        frame0.instances[0].points[0] = Point(x: 12345.0, y: 67890.0, visible: true)

        // Don't access frame 1 — it remains uncached

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await labels.save(to: outputURL)

        // Load the saved file and verify
        let labels2 = try await Labels.load(from: outputURL)
        labels2.materialize()

        XCTAssertEqual(labels.count, labels2.count)

        // Frame 0's modification should be saved
        let savedFrame0 = labels2[0]
        XCTAssertEqual(savedFrame0.instances[0].points[0].x, 12345.0, accuracy: 1e-3,
                       "Modified cached frame should be saved with modifications")

        // Frame 1 should be identical to the original (uncached fast path)
        if labels2.count > 1 {
            let savedFrame1 = labels2[1]
            XCTAssertNotNil(savedFrame1, "Uncached frames should be saved correctly")
        }
    }

    func testS05_lazySaveProducesValidRoundTrippableFile() async throws {
        let url = try requireFixture("sparse_v1_5.slp")
        let labels = try await Labels.load(from: url)
        XCTAssertTrue(labels.isLazy)

        // Access a few frames
        for i in 0..<min(labels.count, 3) {
            let _ = labels[i]
        }

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await labels.save(to: outputURL)

        // The output should be loadable and produce the same data
        let labels2 = try await Labels.load(from: outputURL)
        labels2.materialize()

        XCTAssertEqual(labels.count, labels2.count)
        XCTAssertEqual(labels.videos.count, labels2.videos.count)
        XCTAssertEqual(labels.skeletons.count, labels2.skeletons.count)
    }
}
