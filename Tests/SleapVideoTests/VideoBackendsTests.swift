import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SleapVideo
import SleapIO

// MARK: - Local test helpers (file-private to avoid clashing with SleapVideoTests)

private func makeSolidImage(
    width: Int, height: Int,
    red: CGFloat = 1.0, green: CGFloat = 0.0, blue: CGFloat = 0.0
) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func makeGrayImage(width: Int, height: Int, value: CGFloat) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    ctx.setFillColor(gray: value, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@discardableResult
private func writeMultipageTIFF(_ images: [CGImage], to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.tiff.identifier as CFString, images.count, nil
    ) else { return false }
    for image in images {
        CGImageDestinationAddImage(dest, image, nil)
    }
    return CGImageDestinationFinalize(dest)
}

private func tempURL(ext: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sleap_backends_\(UUID().uuidString).\(ext)")
}

// MARK: - TiffVideo Tests

final class TiffVideoTests: XCTestCase {
    private var tiffURL: URL!

    override func setUp() {
        super.setUp()
        tiffURL = tempURL(ext: "tif")
    }
    override func tearDown() {
        if let u = tiffURL { try? FileManager.default.removeItem(at: u) }
        super.tearDown()
    }

    func testMultipageFrameCount() throws {
        let images = (0..<5).map { i in
            makeSolidImage(width: 40, height: 30, red: CGFloat(i) / 4.0, green: 0, blue: 1)
        }
        XCTAssertTrue(writeMultipageTIFF(images, to: tiffURL))

        let be = try TiffVideo(url: tiffURL)
        XCTAssertEqual(be.frameCount, 5)
        XCTAssertEqual(be.format, .multiPage)
    }

    func testMultipageFrameSize() throws {
        let images = (0..<3).map { _ in makeSolidImage(width: 48, height: 36) }
        XCTAssertTrue(writeMultipageTIFF(images, to: tiffURL))

        let be = try TiffVideo(url: tiffURL)
        XCTAssertEqual(be.frameSize?.width, 48)
        XCTAssertEqual(be.frameSize?.height, 36)
        XCTAssertEqual(be.frameSize?.channels, 3)
    }

    func testMultipageFPSNil() throws {
        let images = [makeSolidImage(width: 16, height: 16)]
        XCTAssertTrue(writeMultipageTIFF(images, to: tiffURL))
        XCTAssertNil(try TiffVideo(url: tiffURL).fps)
    }

    func testReadFrameDimensions() async throws {
        let images = (0..<4).map { _ in makeSolidImage(width: 32, height: 24) }
        XCTAssertTrue(writeMultipageTIFF(images, to: tiffURL))

        let be = try TiffVideo(url: tiffURL)
        let frame = try await be.frame(at: 2)
        XCTAssertEqual(frame.width, 32)
        XCTAssertEqual(frame.height, 24)
    }

    func testGrayscaleMultipageChannels() throws {
        let images = (0..<3).map { i in
            makeGrayImage(width: 20, height: 20, value: CGFloat(i) / 3.0)
        }
        XCTAssertTrue(writeMultipageTIFF(images, to: tiffURL))

        let be = try TiffVideo(url: tiffURL)
        XCTAssertEqual(be.frameCount, 3)
        XCTAssertEqual(be.frameSize?.channels, 1)
    }

    func testOutOfRangeThrows() async throws {
        let images = [makeSolidImage(width: 8, height: 8)]
        XCTAssertTrue(writeMultipageTIFF(images, to: tiffURL))
        let be = try TiffVideo(url: tiffURL)
        do { _ = try await be.frame(at: 99); XCTFail("Expected error") } catch {}
    }

    func testNegativeIndexThrows() async throws {
        let images = [makeSolidImage(width: 8, height: 8)]
        XCTAssertTrue(writeMultipageTIFF(images, to: tiffURL))
        let be = try TiffVideo(url: tiffURL)
        do { _ = try await be.frame(at: -1); XCTFail("Expected error") } catch {}
    }

    func testMissingFileThrows() {
        do {
            _ = try TiffVideo(url: URL(fileURLWithPath: "/nonexistent/x.tif"))
            XCTFail("Expected error")
        } catch {}
    }

    // MARK: Pure stack-shape math (rank-3/4 axis handling)

    func testResolveFormatAutoBecomesMultiPage() {
        XCTAssertEqual(TiffVideo.resolveFormat(.auto, pageCount: 4), .multiPage)
        XCTAssertEqual(TiffVideo.resolveFormat(.HWT, pageCount: 1), .HWT)
    }

    func testResolveShapeTHW() {
        // (T, H, W) stored multi-page: pages are frames, grayscale.
        let s = TiffVideo.resolveShape(
            format: .THW, pageWidth: 30, pageHeight: 20, pageChannels: 1, pageCount: 7)
        XCTAssertEqual(s.frameCount, 7)
        XCTAssertEqual(s.height, 20)
        XCTAssertEqual(s.width, 30)
        XCTAssertEqual(s.channels, 1)
    }

    func testResolveShapeTHWC() {
        // (T, H, W, C) stored multi-page: pages are frames, C channels.
        let s = TiffVideo.resolveShape(
            format: .THWC, pageWidth: 30, pageHeight: 20, pageChannels: 3, pageCount: 5)
        XCTAssertEqual(s.frameCount, 5)
        XCTAssertEqual(s.channels, 3)
    }

    func testResolveShapeHWT() {
        // (H, W, T) single page: T lives on the sample axis.
        let s = TiffVideo.resolveShape(
            format: .HWT, pageWidth: 30, pageHeight: 20, pageChannels: 4, pageCount: 1)
        XCTAssertEqual(s.frameCount, 4)
        XCTAssertEqual(s.height, 20)
        XCTAssertEqual(s.width, 30)
        XCTAssertEqual(s.channels, 1)
    }

    func testResolveShapeCHWT() {
        // Rank-4 single-page CHWT is unrepresentable in ImageIO; falls back to
        // pages-as-frames.
        let s = TiffVideo.resolveShape(
            format: .CHWT, pageWidth: 30, pageHeight: 20, pageChannels: 3, pageCount: 6)
        XCTAssertEqual(s.frameCount, 6)
        XCTAssertEqual(s.height, 20)
        XCTAssertEqual(s.width, 30)
    }
}

// MARK: - SeqVideo Tests

final class SeqVideoTests: XCTestCase {

    /// Build a minimal monochrome `.seq` fixture in memory.
    ///
    /// Layout: 1024-byte header + `frames.count` slots of `trueImageSize` bytes,
    /// where each slot holds `width*height` payload bytes followed by 8 bytes of
    /// (zeroed) timestamp/padding.
    private func makeSeqData(
        width: Int, height: Int, frames: [[UInt8]],
        fps: Double = 30.0, allocatedFrames: Int? = nil
    ) -> Data {
        let headerSize = 1024
        let imageSizeBytes = width * height          // monochrome, 1 channel
        let trueImageSize = imageSizeBytes + 8       // + timestamp padding

        var data = Data(count: headerSize)

        func putU32(_ value: UInt32, at offset: Int) {
            data[offset + 0] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
            data[offset + 2] = UInt8((value >> 16) & 0xFF)
            data[offset + 3] = UInt8((value >> 24) & 0xFF)
        }
        func putF64(_ value: Double, at offset: Int) {
            let bits = value.bitPattern
            for i in 0..<8 { data[offset + i] = UInt8((bits >> (8 * i)) & 0xFF) }
        }

        putU32(0xFEED, at: 0)                        // magic
        // "Norpix seq\n" name at offset 4 (informational)
        for (i, b) in Array("Norpix seq\n".utf8).enumerated() { data[4 + i] = b }
        putU32(5, at: 28)                            // version
        putU32(UInt32(headerSize), at: 32)           // headerSize
        putU32(UInt32(width), at: 548)
        putU32(UInt32(height), at: 552)
        putU32(8, at: 556)                           // bitDepth
        putU32(8, at: 560)                           // bitDepthReal
        putU32(UInt32(imageSizeBytes), at: 564)
        putU32(100, at: 568)                         // imageFormat = monochrome
        putU32(UInt32(allocatedFrames ?? frames.count), at: 572)
        putU32(0, at: 576)                           // origin
        putU32(UInt32(trueImageSize), at: 580)
        putF64(fps, at: 584)

        for payload in frames {
            var slot = payload
            precondition(payload.count == imageSizeBytes)
            slot.append(contentsOf: [UInt8](repeating: 0, count: 8))  // timestamp
            data.append(contentsOf: slot)
        }
        return data
    }

    func testHeaderParse() throws {
        let data = makeSeqData(width: 4, height: 2, frames: [
            [10, 20, 30, 40, 50, 60, 70, 80],
        ])
        let header = try SeqHeader.parse(data)
        XCTAssertEqual(header.magic, 0xFEED)
        XCTAssertEqual(header.width, 4)
        XCTAssertEqual(header.height, 2)
        XCTAssertEqual(header.headerSize, 1024)
        XCTAssertEqual(header.imageFormat, .monochrome)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.imageSizeBytes, 8)
        XCTAssertEqual(header.trueImageSize, 16)
        XCTAssertEqual(header.fps, 30.0, accuracy: 1e-9)
    }

    func testHeaderBadMagicThrows() {
        var data = Data(count: SeqHeader.minHeaderBytes)
        data[0] = 0xAA  // not 0xFEED
        do { _ = try SeqHeader.parse(data); XCTFail("Expected error") } catch {}
    }

    func testHeaderTooSmallThrows() {
        let data = Data(count: 100)
        do { _ = try SeqHeader.parse(data); XCTFail("Expected error") } catch {}
    }

    func testBackendFrameCount() throws {
        let url = tempURL(ext: "seq")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = makeSeqData(width: 4, height: 2, frames: [
            [1, 2, 3, 4, 5, 6, 7, 8],
            [9, 10, 11, 12, 13, 14, 15, 16],
            [17, 18, 19, 20, 21, 22, 23, 24],
        ])
        try data.write(to: url)

        let be = try SeqVideo(url: url)
        XCTAssertEqual(be.frameCount, 3)
        XCTAssertEqual(be.frameSize?.width, 4)
        XCTAssertEqual(be.frameSize?.height, 2)
        XCTAssertEqual(be.frameSize?.channels, 1)
        XCTAssertEqual(be.fps, 30.0)
    }

    func testBackendReadsFramePixels() async throws {
        let url = tempURL(ext: "seq")
        defer { try? FileManager.default.removeItem(at: url) }
        let frame0: [UInt8] = [11, 22, 33, 44, 55, 66, 77, 88]
        let frame1: [UInt8] = [100, 101, 102, 103, 104, 105, 106, 107]
        let data = makeSeqData(width: 4, height: 2, frames: [frame0, frame1])
        try data.write(to: url)

        let be = try SeqVideo(url: url)
        let img0 = try await be.frame(at: 0)
        XCTAssertEqual(img0.width, 4)
        XCTAssertEqual(img0.height, 2)

        // The CGImage keeps our provider bytes; verify the first pixel round-trips.
        let cf = img0.dataProvider?.data
        XCTAssertNotNil(cf)
        let ptr = CFDataGetBytePtr(cf!)
        XCTAssertEqual(ptr?[0], 11)

        let img1 = try await be.frame(at: 1)
        let cf1 = img1.dataProvider!.data
        XCTAssertEqual(CFDataGetBytePtr(cf1)?[0], 100)
    }

    func testBackendOutOfRangeThrows() async throws {
        let url = tempURL(ext: "seq")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = makeSeqData(width: 2, height: 2, frames: [[1, 2, 3, 4]])
        try data.write(to: url)
        let be = try SeqVideo(url: url)
        do { _ = try await be.frame(at: 5); XCTFail("Expected error") } catch {}
    }

    func testAllocatedFramesClampedToFileSize() throws {
        // Header claims 10 frames but only 2 are written; count clamps to 2.
        let url = tempURL(ext: "seq")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = makeSeqData(
            width: 2, height: 2,
            frames: [[1, 2, 3, 4], [5, 6, 7, 8]],
            allocatedFrames: 10
        )
        try data.write(to: url)
        let be = try SeqVideo(url: url)
        XCTAssertEqual(be.frameCount, 2)
    }

    func testImageFormatChannels() {
        XCTAssertEqual(SeqImageFormat.monochrome.channels, 1)
        XCTAssertEqual(SeqImageFormat.rgb.channels, 3)
        XCTAssertEqual(SeqImageFormat.bgr.channels, 3)
        XCTAssertEqual(SeqImageFormat.bgrx.channels, 4)
        XCTAssertTrue(SeqImageFormat.monochrome.isRawUncompressed)
        XCTAssertFalse(SeqImageFormat.jpeg.isRawUncompressed)
    }
}

// MARK: - VideoWriter Tests

#if canImport(AVFoundation)
import AVFoundation

final class VideoWriterTests: XCTestCase {

    func testWriteAndReopenFrameCount() async throws {
        let url = tempURL(ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let frameCount = 8
        let width = 64, height = 48
        let writer = try VideoWriter(url: url, height: height, width: width, fps: 30.0)
        for i in 0..<frameCount {
            let frame = makeSolidImage(
                width: width, height: height,
                red: CGFloat(i) / CGFloat(frameCount), green: 0.2, blue: 0.6)
            try await writer.append(frame)
        }
        try await writer.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let be = try await AVFoundationBackend(url: url)
        XCTAssertNotNil(be.frameCount)
        // AVFoundation derives count from duration*fps; allow ±1 rounding.
        XCTAssertLessThanOrEqual(abs(be.frameCount! - frameCount), 1)
        XCTAssertEqual(be.frameSize?.width, width)
        XCTAssertEqual(be.frameSize?.height, height)

        let firstFrame = try await be.frame(at: 0)
        XCTAssertEqual(firstFrame.width, width)
    }

    func testSaveVideoConvenience() async throws {
        let url = tempURL(ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let width = 48, height = 32
        try await VideoWriter.saveVideo(
            to: url, frames: 0..<6, height: height, width: width, fps: 24.0
        ) { index in
            makeSolidImage(width: width, height: height,
                           red: 0, green: CGFloat(index) / 6.0, blue: 1)
        }

        let be = try await AVFoundationBackend(url: url)
        XCTAssertNotNil(be.frameCount)
        XCTAssertLessThanOrEqual(abs(be.frameCount! - 6), 1)
    }

    func testInvalidDimensionsThrow() {
        do {
            _ = try VideoWriter(url: tempURL(ext: "mp4"), height: 0, width: 10)
            XCTFail("Expected error")
        } catch {}
    }

    func testHEVCCodec() async throws {
        let url = tempURL(ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let width = 64, height = 64
        let writer = try VideoWriter(
            url: url, height: height, width: width, fps: 30.0,
            codec: .hevc, bitRate: 1_000_000, keyframeInterval: 10)
        for _ in 0..<4 {
            try await writer.append(makeSolidImage(width: width, height: height))
        }
        try await writer.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
