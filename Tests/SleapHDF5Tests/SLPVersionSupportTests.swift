import XCTest
import CHDF5
@testable import SleapIO
@testable import SleapHDF5
import SleapVideo

/// Issue 42: SLP format-version support tests.
///
/// Verifies that the reader accepts SLP 1.6-2.4 (loading the datasets it models
/// and skipping the datasets it does not), continues to behave identically for
/// versions <= 1.5, and still rejects versions strictly newer than 2.4.
///
/// Two layers of coverage:
///  1. Direct unit tests of the version-gating decision logic
///     (``SLPReader/validateFormatVersion(_:)`` and
///     ``SLPReader/modelsAnnotationTables(formatId:)``). These are deterministic
///     and require no fixtures.
///  2. End-to-end loads of synthetic HDF5 `.slp` files stamped with the target
///     `format_id`. Real >1.5 fixtures from Python SLEAP are not available in
///     this repo, so the synthetic files below exercise the full read path with
///     the datasets we model plus a set of unmodeled datasets that must be
///     skipped rather than causing a load failure.
final class SLPVersionSupportTests: XCTestCase {

    // MARK: - Direct version-gating logic

    func testMaxSupportedFormatVersionIs24() {
        XCTAssertEqual(kMaxSupportedFormatVersion, 2.4)
    }

    func testValidateFormatVersion_acceptsSupportedVersions() throws {
        // Legacy (<=1.5) and the newly supported 1.6-2.4 range must not throw.
        for version: Float in [1.0, 1.1, 1.2, 1.4, 1.5, 1.6, 2.0, 2.3, 2.4] {
            XCTAssertNoThrow(
                try SLPReader.validateFormatVersion(version),
                "format_id \(version) should be accepted"
            )
        }
    }

    func testValidateFormatVersion_rejectsVersionsAbove24() {
        for version: Float in [2.5, 2.6, 3.0, 10.0] {
            assertThrowsFormatVersionTooNew(version) {
                try SLPReader.validateFormatVersion(version)
            }
        }
    }

    func testValidateFormatVersion_boundaryIsInclusiveAt24() {
        // Exactly at the cap: accepted. Just above the cap: rejected.
        XCTAssertNoThrow(try SLPReader.validateFormatVersion(2.4))
        assertThrowsFormatVersionTooNew(2.5) {
            try SLPReader.validateFormatVersion(2.5)
        }
    }

    func testModelsAnnotationTables_onlyForV15() {
        // ROI/mask tables are modeled for the 1.5 schema only.
        XCTAssertTrue(SLPReader.modelsAnnotationTables(formatId: 1.5))
        // Predates the tables entirely.
        XCTAssertFalse(SLPReader.modelsAnnotationTables(formatId: 1.4))
        XCTAssertFalse(SLPReader.modelsAnnotationTables(formatId: 1.0))
        // Newer versions may use an unmodeled schema, so they are skipped.
        XCTAssertFalse(SLPReader.modelsAnnotationTables(formatId: 1.6))
        XCTAssertFalse(SLPReader.modelsAnnotationTables(formatId: 2.0))
        XCTAssertFalse(SLPReader.modelsAnnotationTables(formatId: 2.4))
    }

    func testUnmodeledDatasetNames_documentsSkippedDatasets() {
        // bboxes/centroids/identities/masks are now modeled and read best-effort;
        // only label images remain unmodeled (epic E7 #47).
        XCTAssertEqual(
            Set(SLPReader.unmodeledDatasetNames),
            ["label_images"]
        )
    }

    // MARK: - End-to-end: newer versions load modeled data

    func testLoadV16_lazyAndEager_loadsModeledData() async throws {
        try await assertModeledDataLoads(formatId: 1.6)
    }

    func testLoadV20_lazyAndEager_loadsModeledData() async throws {
        try await assertModeledDataLoads(formatId: 2.0)
    }

    func testLoadV24_lazyAndEager_loadsModeledData() async throws {
        try await assertModeledDataLoads(formatId: 2.4)
    }

    // MARK: - End-to-end: newer versions READ valid annotation tables

    // The reader gates ROI/mask reads on dataset presence, not format version.
    // A 1.6/2.0 file carrying /rois and /masks in the 1.5-compatible schema must
    // therefore be read (not dropped) — the behavior this fix restored.

    func testLoadV16_validAnnotationTables_areRead() async throws {
        try await assertValidAnnotationTablesLoad(formatId: 1.6)
    }

    func testLoadV20_validAnnotationTables_areRead() async throws {
        try await assertValidAnnotationTablesLoad(formatId: 2.0)
    }

    // MARK: - End-to-end: <=1.5 behavior unchanged

    func testLoadV15_stillLoads() async throws {
        // Regression guard: raising the cap must not change 1.5 behavior.
        let url = try makeVersionFixture(formatId: 1.5, includeBogusAnnotationTables: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let lazy = try await Labels.load(from: url)
        XCTAssertEqual(lazy.videos.count, 2)
        XCTAssertEqual(lazy.count, 2)

        let eager = try await Labels.loadEager(from: url)
        XCTAssertEqual(eager.videos.count, 2)
        XCTAssertEqual(eager.count, 2)
    }

    func testLoadV15_corruptAnnotationTables_throw() async throws {
        // 1.5 is the fully modeled schema, so a genuinely corrupt /masks (and
        // /rois) must surface the read error rather than being skipped.
        let url = try makeVersionFixture(formatId: 1.5, includeBogusAnnotationTables: true)
        defer { try? FileManager.default.removeItem(at: url) }

        await assertLoadThrows(url: url)
    }

    // MARK: - End-to-end: versions above the cap are rejected

    func testLoadV25_lazyAndEager_throwsFormatVersionTooNew() async throws {
        let url = try makeVersionFixture(formatId: 2.5, includeBogusAnnotationTables: false)
        defer { try? FileManager.default.removeItem(at: url) }

        await expectFormatVersionTooNew(2.5) {
            _ = try await Labels.load(from: url)
        }
        await expectFormatVersionTooNew(2.5) {
            _ = try await Labels.loadEager(from: url)
        }
    }

    // MARK: - Shared assertions

    /// Load a synthetic fixture at `formatId` through both the lazy and eager
    /// paths and assert the modeled data (videos + frames) is reconstructed and
    /// that unmodeled datasets did not break the load.
    private func assertModeledDataLoads(
        formatId: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = try makeVersionFixture(formatId: formatId, includeBogusAnnotationTables: true)
        defer { try? FileManager.default.removeItem(at: url) }

        // Lazy path (default Labels.load).
        let lazy = try await Labels.load(from: url)
        XCTAssertEqual(lazy.videos.count, 2, "lazy videos", file: file, line: line)
        XCTAssertEqual(lazy.count, 2, "lazy frame count", file: file, line: line)
        XCTAssertEqual(
            lazy.frames(for: lazy.videos[0]).map(\.frameIndex), [3],
            "lazy video 0 frames", file: file, line: line
        )
        XCTAssertEqual(
            lazy.frames(for: lazy.videos[1]).map(\.frameIndex), [8],
            "lazy video 1 frames", file: file, line: line
        )
        // Unmodeled ROI/mask tables must be skipped for newer versions.
        XCTAssertTrue(lazy.rois.isEmpty, "lazy rois skipped", file: file, line: line)
        XCTAssertTrue(lazy.masks.isEmpty, "lazy masks skipped", file: file, line: line)
        // bboxes/centroids/identities are now read best-effort: the fixture's
        // malformed datasets decode to [] (via catch) rather than failing the load.
        XCTAssertTrue(lazy.bboxes.isEmpty, "lazy bboxes best-effort empty", file: file, line: line)
        XCTAssertTrue(lazy.centroids.isEmpty, "lazy centroids best-effort empty", file: file, line: line)
        XCTAssertTrue(lazy.identities.isEmpty, "lazy identities best-effort empty", file: file, line: line)

        // Eager path.
        let eager = try await Labels.loadEager(from: url)
        XCTAssertEqual(eager.videos.count, 2, "eager videos", file: file, line: line)
        XCTAssertEqual(eager.count, 2, "eager frame count", file: file, line: line)
        XCTAssertEqual(
            eager.frames(for: eager.videos[0]).map(\.frameIndex), [3],
            "eager video 0 frames", file: file, line: line
        )
        XCTAssertEqual(
            eager.frames(for: eager.videos[1]).map(\.frameIndex), [8],
            "eager video 1 frames", file: file, line: line
        )
        XCTAssertTrue(eager.rois.isEmpty, "eager rois skipped", file: file, line: line)
        XCTAssertTrue(eager.masks.isEmpty, "eager masks skipped", file: file, line: line)
        XCTAssertTrue(eager.bboxes.isEmpty, "eager bboxes best-effort empty", file: file, line: line)
        XCTAssertTrue(eager.centroids.isEmpty, "eager centroids best-effort empty", file: file, line: line)
        XCTAssertTrue(eager.identities.isEmpty, "eager identities best-effort empty", file: file, line: line)
    }

    /// Load a fixture at `formatId` carrying valid 1.5-schema `/rois` and
    /// `/masks` through both paths and assert the annotations are read back.
    private func assertValidAnnotationTablesLoad(
        formatId: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = try makeVersionFixture(
            formatId: formatId,
            includeBogusAnnotationTables: false,
            includeValidAnnotationTables: true
        )
        defer { try? FileManager.default.removeItem(at: url) }

        func assertAnnotations(_ labels: Labels, _ path: String) {
            XCTAssertEqual(labels.videos.count, 2, "\(path) videos", file: file, line: line)
            XCTAssertEqual(labels.count, 2, "\(path) frame count", file: file, line: line)

            XCTAssertEqual(labels.rois.count, 1, "\(path) roi count", file: file, line: line)
            if let roi = labels.rois.first {
                XCTAssertEqual(roi.name, "roi_a", "\(path) roi name", file: file, line: line)
                XCTAssertEqual(roi.annotationType, .boundingBox, "\(path) roi type", file: file, line: line)
                XCTAssertEqual(roi.videoIndex, 0, "\(path) roi video", file: file, line: line)
                XCTAssertEqual(roi.frameIndex, 3, "\(path) roi frame", file: file, line: line)
            }

            XCTAssertEqual(labels.masks.count, 1, "\(path) mask count", file: file, line: line)
            if let mask = labels.masks.first {
                XCTAssertEqual(mask.name, "mask_a", "\(path) mask name", file: file, line: line)
                XCTAssertEqual(mask.height, 4, "\(path) mask height", file: file, line: line)
                XCTAssertEqual(mask.width, 4, "\(path) mask width", file: file, line: line)
                XCTAssertEqual(mask.rleCounts, [8, 8], "\(path) mask rle", file: file, line: line)
                XCTAssertEqual(mask.videoIndex, 1, "\(path) mask video", file: file, line: line)
                XCTAssertEqual(mask.frameIndex, 8, "\(path) mask frame", file: file, line: line)
            }
        }

        assertAnnotations(try await Labels.load(from: url), "lazy")
        assertAnnotations(try await Labels.loadEager(from: url), "eager")
    }

    /// Assert that both the lazy and eager load paths throw for `url`.
    private func assertLoadThrows(
        url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await Labels.load(from: url)
            XCTFail("Expected lazy load to throw", file: file, line: line)
        } catch {}
        do {
            _ = try await Labels.loadEager(from: url)
            XCTFail("Expected eager load to throw", file: file, line: line)
        } catch {}
    }

    private func assertThrowsFormatVersionTooNew(
        _ expected: Float,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try body()
            XCTFail("Expected formatVersionTooNew(\(expected)) but nothing was thrown",
                    file: file, line: line)
        } catch let SleapIOError.formatVersionTooNew(version) {
            XCTAssertEqual(version, expected, "wrong version in error", file: file, line: line)
        } catch {
            XCTFail("Expected formatVersionTooNew(\(expected)) but got \(error)",
                    file: file, line: line)
        }
    }

    private func expectFormatVersionTooNew(
        _ expected: Float,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected formatVersionTooNew(\(expected)) but nothing was thrown",
                    file: file, line: line)
        } catch let SleapIOError.formatVersionTooNew(version) {
            XCTAssertEqual(version, expected, "wrong version in error", file: file, line: line)
        } catch {
            XCTFail("Expected formatVersionTooNew(\(expected)) but got \(error)",
                    file: file, line: line)
        }
    }

    // MARK: - Synthetic fixture builder

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_version_\(UUID().uuidString).slp")
    }

    /// Build a minimal but valid synthetic `.slp` file stamped with `formatId`.
    ///
    /// Contains the datasets the reader models — two videos and two frames (one
    /// per video) — plus a set of extra datasets. `label_images` is still
    /// unmodeled and never opened; the malformed `bboxes`/`centroids`/`identities`
    /// datasets are now read best-effort and decode to [] (via catch) without
    /// failing the load.
    ///
    /// Annotation tables are controlled by two flags:
    ///  - `includeBogusAnnotationTables`: writes deliberately malformed
    ///    `masks`/`rois` datasets. For versions > 1.5 these must be skipped
    ///    gracefully (the load succeeds, tables empty); for 1.5 — the fully
    ///    modeled schema — the read error must surface.
    ///  - `includeValidAnnotationTables`: writes `masks`/`rois` in the
    ///    1.5-compatible compound schema. Because the reader now gates on
    ///    dataset presence rather than format version, versions > 1.5 must
    ///    READ these rather than dropping them.
    private func makeVersionFixture(
        formatId: Float,
        includeBogusAnnotationTables: Bool,
        includeValidAnnotationTables: Bool = false
    ) throws -> URL {
        let url = tempURL()

        let file = try HDF5File.create(path: url.path)

        let metadata = try file.createGroup(name: "metadata")
        try metadata.writeFloatAttribute(name: "format_id", value: formatId)
        try metadata.writeStringAttribute(
            name: "json",
            value: #"{"nodes":[],"provenance":{},"skeletons":[]}"#
        )

        try file.writeVLenStringDataset(
            name: "videos_json",
            strings: [
                #"{"id":10,"backend":{"filename":"video_a.mp4","type":"media"}}"#,
                #"{"id":20,"backend":{"filename":"video_b.mp4","type":"media"}}"#,
            ]
        )

        // frames compound table: two rows referencing videos 10 and 20.
        let compType = try HDF5Datatype.createCompound(size: 36)
        try compType.insertField(name: "frame_id", offset: 0, type: shim_H5T_NATIVE_UINT64())
        try compType.insertField(name: "video", offset: 8, type: shim_H5T_NATIVE_UINT32())
        try compType.insertField(name: "frame_idx", offset: 12, type: shim_H5T_NATIVE_UINT64())
        try compType.insertField(name: "instance_id_start", offset: 20, type: shim_H5T_NATIVE_UINT64())
        try compType.insertField(name: "instance_id_end", offset: 28, type: shim_H5T_NATIVE_UINT64())

        let space = try HDF5Dataspace.create(dims: [2])
        let frames = try file.createDataset(name: "frames", type: compType, space: space)

        var buffer = Data(count: 2 * 36)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!

            base.storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self)
            base.storeBytes(of: UInt32(10), toByteOffset: 8, as: UInt32.self)
            base.storeBytes(of: UInt64(3), toByteOffset: 12, as: UInt64.self)
            base.storeBytes(of: UInt64(0), toByteOffset: 20, as: UInt64.self)
            base.storeBytes(of: UInt64(0), toByteOffset: 28, as: UInt64.self)

            let second = base + 36
            second.storeBytes(of: UInt64(1), toByteOffset: 0, as: UInt64.self)
            second.storeBytes(of: UInt32(20), toByteOffset: 8, as: UInt32.self)
            second.storeBytes(of: UInt64(8), toByteOffset: 12, as: UInt64.self)
            second.storeBytes(of: UInt64(0), toByteOffset: 20, as: UInt64.self)
            second.storeBytes(of: UInt64(0), toByteOffset: 28, as: UInt64.self)
        }
        try buffer.withUnsafeBytes { ptr in
            try frames.writeRaw(ptr.baseAddress!, memType: compType.id)
        }

        // Extra datasets. `label_images` is unmodeled and never opened. The
        // malformed `bboxes`/`centroids` datasets are now read best-effort: the
        // compound-field reads fail and are caught, yielding []. `identities` is a
        // decoy — the reader looks for `identities_json`, so this name is ignored.
        // All are present to prove they do not trigger a load failure.
        try file.writeVLenStringDataset(name: "bboxes", strings: ["unmodeled"])
        try file.writeVLenStringDataset(name: "centroids", strings: ["unmodeled"])
        try file.writeVLenStringDataset(name: "identities", strings: ["unmodeled"])
        try file.writeVLenStringDataset(name: "label_images", strings: ["unmodeled"])
        try file.writeDataset(name: "misc_unmodeled", data: [Int32(1), Int32(2)],
                              type: shim_H5T_NATIVE_INT32())

        // Annotation tables. Valid tables take precedence over bogus ones so the
        // two flags never collide on the same dataset name.
        if includeValidAnnotationTables {
            // 1.5-compatible compound schema: for versions > 1.5 the reader must
            // now READ these (the presence-gated behavior the fix restored).
            try Self.writeValidROIs(to: file)
            try Self.writeValidMasks(to: file)
        } else if includeBogusAnnotationTables {
            // Deliberately malformed: readMasks/readROIs fail to parse these. A
            // successful load proves they are skipped for versions > 1.5, while a
            // 1.5 load must surface the read error (modeled schema).
            try file.writeVLenStringDataset(name: "masks", strings: ["not-a-mask-table"])
            try file.writeVLenStringDataset(name: "rois", strings: ["not-an-roi-table"])
        }

        return url
    }

    /// Write a valid `/rois` compound dataset (1.5-compatible schema, mirrors
    /// ``SLPWriter``): one bounding-box ROI on video 0, frame 3, named "roi_a".
    /// No `/roi_wkb` is written, so the geometry decodes to an empty point list,
    /// which is enough to prove the compound-field reads succeed and the ROI is
    /// materialized rather than dropped.
    private static func writeValidROIs(to file: HDF5File) throws {
        let rowSize = 40
        let compType = try HDF5Datatype.createCompound(size: rowSize)
        try compType.insertField(name: "annotation_type", offset: 0, type: shim_H5T_NATIVE_UINT8())
        try compType.insertField(name: "video", offset: 4, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "frame_idx", offset: 8, type: shim_H5T_NATIVE_INT64())
        try compType.insertField(name: "track", offset: 16, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "score", offset: 20, type: shim_H5T_NATIVE_FLOAT())
        try compType.insertField(name: "wkb_start", offset: 24, type: shim_H5T_NATIVE_UINT64())
        try compType.insertField(name: "wkb_end", offset: 32, type: shim_H5T_NATIVE_UINT64())

        var buffer = Data(count: rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let p = ptr.baseAddress!
            p.storeBytes(of: UInt8(0), toByteOffset: 0, as: UInt8.self)   // boundingBox
            p.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)   // video 0
            p.storeBytes(of: Int64(3), toByteOffset: 8, as: Int64.self)   // frame 3
            p.storeBytes(of: Int32(-1), toByteOffset: 16, as: Int32.self) // no track
            p.storeBytes(of: Float(0.9), toByteOffset: 20, as: Float.self)
            p.storeBytes(of: UInt64(0), toByteOffset: 24, as: UInt64.self)
            p.storeBytes(of: UInt64(0), toByteOffset: 32, as: UInt64.self)
        }

        let space = try HDF5Dataspace.create(dims: [1])
        let ds = try file.createDataset(name: "rois", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }
        try ds.writeStringAttribute(name: "names", value: #"["roi_a"]"#)
    }

    /// Write a valid `/masks` compound dataset plus its `/mask_rle` payload
    /// (1.5-compatible schema, mirrors ``SLPWriter``): one 4x4 segmentation mask
    /// on video 1, frame 8, named "mask_a", with RLE counts [8, 8].
    private static func writeValidMasks(to file: HDF5File) throws {
        // RLE payload: counts [8, 8] packed as little-endian uint32.
        var rle = Data()
        for count in [UInt32(8), UInt32(8)] {
            var v = count
            withUnsafeBytes(of: &v) { rle.append(contentsOf: $0) }
        }
        try file.writeDataset(name: "mask_rle", data: [UInt8](rle), type: shim_H5T_NATIVE_UINT8())

        let rowSize = 48
        let compType = try HDF5Datatype.createCompound(size: rowSize)
        try compType.insertField(name: "height", offset: 0, type: shim_H5T_NATIVE_UINT32())
        try compType.insertField(name: "width", offset: 4, type: shim_H5T_NATIVE_UINT32())
        try compType.insertField(name: "annotation_type", offset: 8, type: shim_H5T_NATIVE_UINT8())
        try compType.insertField(name: "video", offset: 12, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "frame_idx", offset: 16, type: shim_H5T_NATIVE_INT64())
        try compType.insertField(name: "track", offset: 24, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "score", offset: 28, type: shim_H5T_NATIVE_FLOAT())
        try compType.insertField(name: "rle_start", offset: 32, type: shim_H5T_NATIVE_UINT64())
        try compType.insertField(name: "rle_end", offset: 40, type: shim_H5T_NATIVE_UINT64())

        var buffer = Data(count: rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let p = ptr.baseAddress!
            p.storeBytes(of: UInt32(4), toByteOffset: 0, as: UInt32.self)  // height
            p.storeBytes(of: UInt32(4), toByteOffset: 4, as: UInt32.self)  // width
            p.storeBytes(of: UInt8(5), toByteOffset: 8, as: UInt8.self)    // segmentationMask
            p.storeBytes(of: Int32(1), toByteOffset: 12, as: Int32.self)   // video 1
            p.storeBytes(of: Int64(8), toByteOffset: 16, as: Int64.self)   // frame 8
            p.storeBytes(of: Int32(-1), toByteOffset: 24, as: Int32.self)  // no track
            p.storeBytes(of: Float(0.8), toByteOffset: 28, as: Float.self)
            p.storeBytes(of: UInt64(0), toByteOffset: 32, as: UInt64.self) // rle_start
            p.storeBytes(of: UInt64(rle.count), toByteOffset: 40, as: UInt64.self) // rle_end
        }

        let space = try HDF5Dataspace.create(dims: [1])
        let ds = try file.createDataset(name: "masks", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }
        try ds.writeStringAttribute(name: "names", value: #"["mask_a"]"#)
    }
}
