import XCTest
import CHDF5
@testable import SleapIO
@testable import SleapHDF5

/// P402–P403: Labels.load/.save schema sniffing and format routing for Phase 4 HDF5 formats.
///
/// These tests require .h5 fixture files in Tests/Fixtures/phase4/.
/// Tests will skip gracefully if fixtures are not available.
final class LabelsIOAdvancedFormatTests: XCTestCase {

    // MARK: - Helpers

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SleapHDF5Tests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        packageRoot()
            .appendingPathComponent("Tests/Fixtures/phase4")
            .appendingPathComponent(relativePath)
    }

    private func requireFixtureURL(_ name: String,
                                   file: StaticString = #file,
                                   line: UInt = #line) throws -> URL {
        let url = fixtureURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Fixture '\(name)' not found — generate phase4 fixtures first")
        }
        return url
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_labelsio_adv_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMinimalLabels() -> Labels {
        let skeleton = Skeleton(name: "animal", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
            Node(name: "tail"),
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])
        skeleton.addEdge(from: skeleton.nodes[1], to: skeleton.nodes[2])

        let track = Track(name: "animal_0")
        let video = Video(filename: "test_video.mp4")

        let points = PointsArray(points: [
            Point(x: 100, y: 200, visible: true, complete: true),
            Point(x: 150, y: 250, visible: true, complete: true),
            Point(x: 200, y: 300, visible: true, complete: true),
        ])
        let instance = Instance(skeleton: skeleton, points: points, track: track)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [instance])

        return Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )
    }

    // MARK: - P402: Schema sniffing for .h5 files

    func testP402_analysisH5Sniffing() async throws {
        let url = try requireFixtureURL("analysis_h5/analysis_minimal.h5")

        // Labels.load should sniff the Analysis HDF5 schema and dispatch correctly.
        let labels = try await Labels.load(from: url)

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.frameCount, 3)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertFalse(labels.isLazy, "Analysis HDF5 import should be eager")
    }

    func testP402_jabsSniffing() async throws {
        let url = try requireFixtureURL("jabs_h5/jabs_single_animal.h5")

        // JABS may require config for node names. If schema sniffing dispatches
        // to JABS and the file has embedded node names, it should succeed.
        // If not, it should throw a helpful error about needing config.
        do {
            let labels = try await Labels.load(from: url)
            // If it succeeds, verify it loaded correctly.
            XCTAssertGreaterThan(labels.frameCount, 0)
            XCTAssertFalse(labels.isLazy)
        } catch let error as SleapIOError {
            // Acceptable: JABS may need explicit config via JABSCodec.read directly.
            guard case .unsupportedFormat(let msg) = error else {
                XCTFail("Expected unsupportedFormat with guidance, got \(error)")
                return
            }
            XCTAssertTrue(msg.lowercased().contains("jabs") || msg.lowercased().contains("config"),
                          "Error message should mention JABS or config: \(msg)")
        }
    }

    func testP402_dlcSniffing() async throws {
        let url = try requireFixtureURL("dlc_h5/dlc_single_animal.h5")

        // Labels.load should sniff the DLC schema and dispatch correctly.
        let labels = try await Labels.load(from: url)

        XCTAssertGreaterThan(labels.frameCount, 0)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertFalse(labels.isLazy, "DLC import should be eager")
    }

    func testP402_unknownH5SchemaThrows() async throws {
        // Create a minimal HDF5 file that doesn't match any known schema.
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("unknown_schema.h5")

        // Write a bare HDF5 file with just a single unrelated dataset.
        // We use the HDF5 wrapper directly since it's @testable.
        do {
            let file = try HDF5File.create(path: url.path)
            try file.writeDataset(name: "random_data", data: [1.0, 2.0, 3.0], type: shim_H5T_NATIVE_DOUBLE())
            // file closes on deinit
        }

        do {
            _ = try await Labels.load(from: url)
            XCTFail("Loading an unknown H5 schema should throw")
        } catch let error as SleapIOError {
            guard case .unsupportedFormat = error else {
                XCTFail("Expected SleapIOError.unsupportedFormat, got \(error)")
                return
            }
        }
    }

    // MARK: - P403: .h5 save requires explicit format

    func testP403_h5SaveRequiresExplicitFormat() async throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let outputURL = dir.appendingPathComponent("output.h5")
        let labels = makeMinimalLabels()

        // Saving with .h5 extension without explicit format should throw unsupportedFormat
        // with a guidance message telling the user to specify the format.
        do {
            try await labels.save(to: outputURL)
            XCTFail("Saving .h5 without explicit format should throw")
        } catch let error as SleapIOError {
            guard case .unsupportedFormat(let msg) = error else {
                XCTFail("Expected SleapIOError.unsupportedFormat, got \(error)")
                return
            }
            // The error message should guide the user.
            XCTAssertFalse(msg.isEmpty, "Error message should provide guidance")
        }
    }

    func testP403_explicitAnalysisH5Save() async throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let outputURL = dir.appendingPathComponent("export.h5")
        let labels = makeMinimalLabels()

        // Saving with explicit .analysisHDF5 format should succeed.
        try await labels.save(to: outputURL, format: .analysisHDF5)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path),
                      "Output file should exist after save")

        // Verify the saved file can be read back.
        let reloaded = try AnalysisHDF5Codec.read(from: outputURL.path)
        XCTAssertEqual(reloaded.frameCount, 1)
    }

    func testP403_explicitJABSSave() async throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let outputURL = dir.appendingPathComponent("export_jabs.h5")
        let labels = makeMinimalLabels()

        // JABS save may need config. If Labels.save supports .jabs format,
        // it should either succeed or throw a helpful error about needing config.
        do {
            try await labels.save(to: outputURL, format: .jabs)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        } catch let error as SleapIOError {
            // Acceptable: JABS may require explicit config via JABSCodec.write directly.
            guard case .unsupportedFormat(let msg) = error else {
                XCTFail("Expected unsupportedFormat with guidance, got \(error)")
                return
            }
            XCTAssertTrue(msg.lowercased().contains("jabs") || msg.lowercased().contains("config"),
                          "Error message should mention JABS or config: \(msg)")
        }
    }
}
