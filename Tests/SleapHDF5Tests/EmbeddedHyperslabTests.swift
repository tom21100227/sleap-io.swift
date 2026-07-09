import XCTest
import CoreGraphics
import CHDF5
@testable import SleapIO
@testable import SleapHDF5

/// Issue #67: single-frame hyperslab reads for embedded HDF5 video.
///
/// `EmbeddedVideo.readFrames` slices one frame at a time out of the embedded
/// `video` dataset (``EmbeddedVideo/ReadStrategy/perFrame``) instead of reading
/// the whole dataset into memory in one call. These tests assert that the
/// per-frame path produces byte-for-byte and image-for-image identical output to
/// the legacy whole-dataset path (``EmbeddedVideo/ReadStrategy/wholeDataset``),
/// and that a single-frame read materializes only one frame's bytes.
///
/// Two layouts are covered:
/// - variable-length per frame (the committed `packaged_frames_v1_5.pkg.slp`
///   fixture, `/video0/video` is a vlen `int8` dataset), and
/// - fixed-length rank-2 `(N, maxBytes)` `int8` (built synthetically here, since
///   the real fixed-length fixture is a gitignored multi-hundred-MB file).
final class EmbeddedHyperslabTests: XCTestCase {

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
            .appendingPathComponent("sleap_hyperslab_\(UUID().uuidString).\(ext)")
    }

    // MARK: - Image helpers

    /// Create a solid-color RGBA image for building deterministic PNG frames.
    private func makeSolidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                         blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Extract raw RGBA pixels from a decoded image for pixel-exact comparison.
    private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width
        let h = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: w * h * 4))
    }

    /// Build a synthetic embedded video group with a fixed-length rank-2 `int8`
    /// dataset `(frameCount, rowLen)` holding zero-padded PNG frames — the layout
    /// used by Python SLEAP for multi-frame embedded videos and by the large
    /// `training_embedded.pkg.slp` stress fixture.
    private func makeFixedLengthEmbeddedFixture(frameCount: Int)
        throws -> (url: URL, pngs: [Data], rowLen: Int, frameNumbers: [Int]) {
        // Distinct colors so a wrong-row slice would be detected.
        var pngs: [Data] = []
        for i in 0..<frameCount {
            guard let img = makeSolidImage(width: 8, height: 8,
                                           r: UInt8(10 + 40 * i), g: 60, b: 120),
                  let png = EmbeddedVideo.encodePNG(image: img) else {
                throw XCTSkip("PNG encoding unavailable on this platform")
            }
            pngs.append(png)
        }

        // Pad every row out to a common length (mirrors HDF5 fixed-length rows).
        let rowLen = (pngs.map { $0.count }.max() ?? 0) + 16
        var flat = [Int8](repeating: 0, count: frameCount * rowLen)
        for (i, png) in pngs.enumerated() {
            let base = i * rowLen
            for (j, byte) in png.enumerated() {
                flat[base + j] = Int8(bitPattern: byte)
            }
        }

        let url = tempURL()
        let file = try HDF5File.create(path: url.path)
        let group = try file.createGroup(name: "video0")

        let int8Type = try HDF5Datatype.copy(shim_H5T_NATIVE_INT8())
        let space = try HDF5Dataspace.create(dims: [frameCount, rowLen])
        let ds = try group.createDataset(name: "video", type: int8Type, space: space)
        try ds.write(flat, memType: shim_H5T_NATIVE_INT8())
        try ds.writeStringAttribute(name: "format", value: "png")
        try ds.writeStringAttribute(name: "channel_order", value: "RGB")

        // Arbitrary (sparse, ascending) source frame indices.
        let frameNumbers = (0..<frameCount).map { $0 * 2 }
        try group.writeDataset(name: "frame_numbers",
                               data: frameNumbers.map { UInt64($0) },
                               type: shim_H5T_NATIVE_UINT64())

        let src = try group.createGroup(name: "source_video")
        try src.writeStringAttribute(name: "json", value: "{}")

        return (url, pngs, rowLen, frameNumbers)
    }

    // MARK: - Parity: variable-length layout (committed fixture)

    /// Per-frame vlen element reads reproduce the whole-dataset read exactly, both
    /// in raw bytes and in decoded pixels, for the committed vlen fixture.
    func testVLenPerFrameMatchesWholeDatasetFixture() throws {
        let url = try requireFixture("packaged_frames_v1_5.pkg.slp")
        let file = try HDF5File.openReadOnly(path: url.path)

        let whole = try EmbeddedVideo.readFrames(
            from: file, videoGroupName: "video0", formatId: 1.5, strategy: .wholeDataset)
        let perFrame = try EmbeddedVideo.readFrames(
            from: file, videoGroupName: "video0", formatId: 1.5, strategy: .perFrame)

        XCTAssertFalse(whole.frames.isEmpty, "Fixture should contain embedded frames")
        XCTAssertEqual(whole.format, "png")
        // Raw byte parity across every frame.
        XCTAssertEqual(perFrame.frames, whole.frames,
                       "Per-frame vlen reads must match the whole-dataset bytes exactly")
        XCTAssertEqual(perFrame.frameSize?.height, whole.frameSize?.height)
        XCTAssertEqual(perFrame.frameSize?.width, whole.frameSize?.width)

        // Decoded-image parity for a representative frame.
        let sourceIdx = whole.frames.keys.sorted()[0]
        guard let wholeImg = EmbeddedVideo.decodeImage(from: whole.frames[sourceIdx]!),
              let perFrameImg = EmbeddedVideo.decodeImage(from: perFrame.frames[sourceIdx]!) else {
            return XCTFail("Failed to decode embedded frame \(sourceIdx)")
        }
        XCTAssertEqual(perFrameImg.width, wholeImg.width)
        XCTAssertEqual(perFrameImg.height, wholeImg.height)
        XCTAssertEqual(rgbaPixels(perFrameImg), rgbaPixels(wholeImg),
                       "Per-frame and whole-dataset decodes must be pixel-identical")
    }

    /// A single vlen element read returns exactly one frame's bytes — matching the
    /// corresponding element of the whole-dataset read, and never the whole dataset
    /// — demonstrating bounded memory.
    func testVLenSingleElementReadIsBounded() throws {
        let url = try requireFixture("packaged_frames_v1_5.pkg.slp")
        let file = try HDF5File.openReadOnly(path: url.path)

        let group = try file.openGroup(name: "video0")
        let ds = try group.openDataset(name: "video")

        // Whole-dataset vlen read, in native dataset order.
        let allElements = try ds.readVLenBytes()
        guard allElements.count >= 2 else {
            throw XCTSkip("Need at least two embedded frames for a bounded-read check")
        }
        let totalBytes = allElements.reduce(0) { $0 + $1.count }

        for row in 0..<allElements.count {
            let single = try EmbeddedVideo.readVLenElementBytes(dataset: ds, rowIndex: row)
            // Correct: matches the corresponding element from the whole read.
            XCTAssertEqual(single, allElements[row],
                           "Single element read at row \(row) must match the whole-read element")
            // Bounded: a single frame is strictly smaller than the whole dataset.
            XCTAssertLessThan(single.count, totalBytes,
                              "A single-frame read must not materialize every frame's bytes")
        }
    }

    // MARK: - Parity: fixed-length rank-2 layout (synthetic fixture)

    /// Per-frame row hyperslab reads reproduce the whole-dataset read exactly for
    /// the fixed-length `(N, maxBytes)` `int8` layout, including PNG-marker trimming
    /// of the zero padding.
    func testFixedLengthPerFrameMatchesWholeDataset() throws {
        let fixture = try makeFixedLengthEmbeddedFixture(frameCount: 4)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let file = try HDF5File.openReadOnly(path: fixture.url.path)
        let whole = try EmbeddedVideo.readFrames(
            from: file, videoGroupName: "video0", formatId: 1.5, strategy: .wholeDataset)
        let perFrame = try EmbeddedVideo.readFrames(
            from: file, videoGroupName: "video0", formatId: 1.5, strategy: .perFrame)

        XCTAssertEqual(perFrame.frames, whole.frames,
                       "Per-frame row reads must match the whole-dataset bytes exactly")
        XCTAssertEqual(whole.frames.count, fixture.frameNumbers.count)

        // Each recovered frame equals the original PNG (padding trimmed away).
        for (i, sourceIdx) in fixture.frameNumbers.enumerated() {
            XCTAssertEqual(perFrame.frames[sourceIdx], fixture.pngs[i],
                           "Recovered frame \(sourceIdx) must equal the original PNG bytes")
        }

        // Decoded-pixel parity for a representative frame.
        let sourceIdx = fixture.frameNumbers[1]
        guard let wholeImg = EmbeddedVideo.decodeImage(from: whole.frames[sourceIdx]!),
              let perFrameImg = EmbeddedVideo.decodeImage(from: perFrame.frames[sourceIdx]!) else {
            return XCTFail("Failed to decode synthetic embedded frame \(sourceIdx)")
        }
        XCTAssertEqual(rgbaPixels(perFrameImg), rgbaPixels(wholeImg),
                       "Per-frame and whole-dataset decodes must be pixel-identical")
    }

    /// A single row hyperslab read pulls exactly one row (`rowLen` bytes) out of an
    /// `(N, rowLen)` dataset, never the full `N * rowLen` — memory is bounded to a
    /// single frame regardless of frame count.
    func testFixedLengthSingleRowReadIsBounded() throws {
        let frameCount = 5
        let fixture = try makeFixedLengthEmbeddedFixture(frameCount: frameCount)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let file = try HDF5File.openReadOnly(path: fixture.url.path)
        let group = try file.openGroup(name: "video0")
        let ds = try group.openDataset(name: "video")
        let shape = ds.shape
        XCTAssertEqual(shape, [frameCount, fixture.rowLen])

        let wholeDatasetElements = shape[0] * shape[1]
        for row in 0..<frameCount {
            let rowBytes = try EmbeddedVideo.readRowBytes(
                dataset: ds, rowIndex: row, shape: shape)
            // Bounded: exactly one row, not the entire dataset.
            XCTAssertEqual(rowBytes.count, fixture.rowLen,
                           "A single-row read must return exactly one frame's row length")
            XCTAssertLessThan(rowBytes.count, wholeDatasetElements,
                              "A single-row read must not materialize the whole dataset")
            // The un-trimmed row still begins with the frame's PNG payload.
            XCTAssertEqual(Array(rowBytes.prefix(fixture.pngs[row].count)),
                           Array(fixture.pngs[row]),
                           "Row \(row) prefix must equal the original PNG bytes")
        }
    }
}
