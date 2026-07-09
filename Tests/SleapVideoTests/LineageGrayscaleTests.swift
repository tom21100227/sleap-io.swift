import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SleapVideo
import SleapIO

// MARK: - File-private helpers (named to avoid clashing with other test files)

private func lgMakeColorImage(
    width: Int, height: Int,
    red: CGFloat, green: CGFloat, blue: CGFloat
) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Fill with a color in the context's OWN DeviceRGB space; the deprecated
    // CGColor(red:green:blue:alpha:) init uses a generic/sRGB space, which gets
    // color-matched into DeviceRGB and shifts a pure red to ~[255,38,0].
    ctx.setFillColor(CGColor(colorSpace: colorSpace,
                             components: [red, green, blue, 1.0])!)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func lgMakeGrayImage(width: Int, height: Int, value: CGFloat) -> CGImage {
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
private func lgWritePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

/// Write `images` as `frame_0000.png`, `frame_0001.png`, ... into a fresh temp dir.
private func lgWriteImageSequence(_ images: [CGImage]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sleap_lineage_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (i, image) in images.enumerated() {
        lgWritePNG(image, to: dir.appendingPathComponent(String(format: "frame_%04d.png", i)))
    }
    return dir
}

private func lgCleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - source_video lineage: restoreOriginalVideos (#54)

final class VideoLineageRestoreTests: XCTestCase {

    /// A single-level embedded video is swapped back to its external source, and
    /// all references (labeled frames, suggestions) are repointed.
    func testRestoreSwapsEmbeddedToSource() throws {
        let external = Video(filename: "/videos/original.mp4", backendType: "media")
        let embedded = Video(filename: ".", backendType: "hdf5")
        embedded.sourceVideo = external

        let frame = LabeledFrame(video: embedded, frameIndex: 0)
        let suggestion = SuggestionFrame(video: embedded, frameIndex: 5)
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [embedded],
            skeletons: [],
            tracks: [],
            suggestions: [suggestion]
        )

        let swapped = labels.restoreOriginalVideos()

        XCTAssertEqual(swapped, 1)
        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertTrue(labels.videos[0] === external)
        XCTAssertEqual(labels.videos[0].filename, "/videos/original.mp4")

        // Frame repointed to the restored external video.
        let restoredFrames = labels.frames(for: external)
        XCTAssertEqual(restoredFrames.count, 1)
        XCTAssertTrue(restoredFrames[0].video === external)
        XCTAssertEqual(restoredFrames[0].frameIndex, 0)
        XCTAssertTrue(labels.frames(for: embedded).isEmpty)

        // Suggestion repointed as well.
        XCTAssertTrue(labels.suggestions[0].video === external)
    }

    /// A video with no `sourceVideo` is left untouched (no swap, no rebuild).
    func testRestoreNoSourceIsNoOp() throws {
        let plain = Video(filename: "/videos/plain.mp4", backendType: "media")
        let frame = LabeledFrame(video: plain, frameIndex: 3)
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [plain],
            skeletons: [],
            tracks: []
        )

        let swapped = labels.restoreOriginalVideos()

        XCTAssertEqual(swapped, 0)
        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertTrue(labels.videos[0] === plain)
        // The unaffected frame object is reused as-is.
        XCTAssertTrue(labels.frames(for: plain).first === frame)
    }

    /// A multi-level lineage `top <- mid <- root` restores to the chain root.
    func testRestoreMultiLevelChainToRoot() throws {
        let root = Video(filename: "/videos/root.mp4", backendType: "media")
        let mid = Video(filename: ".", backendType: "hdf5")
        mid.sourceVideo = root
        let top = Video(filename: ".", backendType: "hdf5")
        top.sourceVideo = mid

        // Sanity: originalVideo resolves to the chain root.
        XCTAssertTrue(top.originalVideo === root)

        let frame = LabeledFrame(video: top, frameIndex: 0)
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [top],
            skeletons: [],
            tracks: []
        )

        let swapped = labels.restoreOriginalVideos()

        XCTAssertEqual(swapped, 1)
        XCTAssertTrue(labels.videos[0] === root)
        XCTAssertTrue(labels.frames(for: root).first?.video === root)
    }

    /// Video-table order and positions are preserved; only sourced videos move.
    func testRestorePreservesOrderAndUnaffectedVideos() throws {
        let externalA = Video(filename: "/videos/a.mp4", backendType: "media")
        let embeddedA = Video(filename: ".", backendType: "hdf5")
        embeddedA.sourceVideo = externalA
        let plainB = Video(filename: "/videos/b.mp4", backendType: "media")

        let frameA = LabeledFrame(video: embeddedA, frameIndex: 0)
        let frameB = LabeledFrame(video: plainB, frameIndex: 1)
        let labels = Labels(
            frameStore: EagerFrameStore(frames: [frameA, frameB]),
            videos: [embeddedA, plainB],
            skeletons: [],
            tracks: []
        )

        let swapped = labels.restoreOriginalVideos()

        XCTAssertEqual(swapped, 1)
        XCTAssertEqual(labels.videos.count, 2)
        XCTAssertTrue(labels.videos[0] === externalA)
        XCTAssertTrue(labels.videos[1] === plainB)
        XCTAssertTrue(labels.frames(for: externalA).first?.video === externalA)
        // The unaffected frame object survives unchanged.
        XCTAssertTrue(labels.frames(for: plainB).first === frameB)
    }
}

// MARK: - Grayscale autodetect (#66)

final class GrayscaleDetectionTests: XCTestCase {

    /// The pixel sampler flags a synthetic gray image as grayscale and a colored
    /// image as color.
    func testIsGrayscaleHelper() {
        let gray = lgMakeGrayImage(width: 12, height: 8, value: 0.5)
        XCTAssertTrue(VideoPixelBuffer.isGrayscale(gray))

        let red = lgMakeColorImage(width: 12, height: 8, red: 1, green: 0, blue: 0)
        XCTAssertFalse(VideoPixelBuffer.isGrayscale(red))

        // A gray-valued RGB image (R == G == B) is still grayscale.
        let neutral = lgMakeColorImage(width: 12, height: 8, red: 0.4, green: 0.4, blue: 0.4)
        XCTAssertTrue(VideoPixelBuffer.isGrayscale(neutral))
    }

    /// An image sequence of gray frames autodetects a single channel; a color
    /// sequence reports three channels.
    func testImageSequenceGrayscaleAutodetect() throws {
        let grayDir = try lgWriteImageSequence(
            (0..<3).map { _ in lgMakeGrayImage(width: 20, height: 16, value: 0.5) }
        )
        defer { lgCleanup(grayDir) }
        let grayBackend = try ImageSequenceBackend(directory: grayDir)
        XCTAssertEqual(grayBackend.frameSize?.channels, 1)
        XCTAssertEqual(grayBackend.frameSize?.width, 20)
        XCTAssertEqual(grayBackend.frameSize?.height, 16)

        let colorDir = try lgWriteImageSequence(
            (0..<3).map { _ in lgMakeColorImage(width: 20, height: 16, red: 1, green: 0, blue: 0) }
        )
        defer { lgCleanup(colorDir) }
        let colorBackend = try ImageSequenceBackend(directory: colorDir)
        XCTAssertEqual(colorBackend.frameSize?.channels, 3)
    }
}

// MARK: - Raw (H, W, C) frame output (#66)

final class RawFrameOutputTests: XCTestCase {

    /// A color frame exposes a tightly-packed `(H, W, 3)` RGB buffer.
    func testRawFrameColorShapeAndContent() async throws {
        let dir = try lgWriteImageSequence(
            [lgMakeColorImage(width: 4, height: 3, red: 1, green: 0, blue: 0)]
        )
        defer { lgCleanup(dir) }

        let backend = try ImageSequenceBackend(directory: dir)
        XCTAssertEqual(backend.frameSize?.channels, 3)

        let raw = try await backend.rawFrame(at: 0)
        XCTAssertEqual(raw.height, 3)
        XCTAssertEqual(raw.width, 4)
        XCTAssertEqual(raw.channels, 3)
        XCTAssertEqual(raw.shape.channels, 3)
        XCTAssertEqual(raw.bytes.count, 3 * 4 * 3)

        // First pixel is red-dominant. Allow a small tolerance for PNG/ICC
        // round-tripping through the image sequence on disk.
        XCTAssertGreaterThan(raw.bytes[0], 250)  // R
        XCTAssertLessThan(raw.bytes[1], 5)        // G
        XCTAssertLessThan(raw.bytes[2], 5)        // B
    }

    /// A grayscale frame collapses to a `(H, W, 1)` single-channel buffer.
    func testRawFrameGrayscaleSingleChannel() async throws {
        let dir = try lgWriteImageSequence(
            [lgMakeGrayImage(width: 5, height: 4, value: 0.5)]
        )
        defer { lgCleanup(dir) }

        let backend = try ImageSequenceBackend(directory: dir)
        XCTAssertEqual(backend.frameSize?.channels, 1)

        let raw = try await backend.rawFrame(at: 0)
        XCTAssertEqual(raw.height, 4)
        XCTAssertEqual(raw.width, 5)
        XCTAssertEqual(raw.channels, 1)
        XCTAssertEqual(raw.bytes.count, 5 * 4)

        // A solid gray frame is spatially uniform and non-black.
        let first = raw.bytes[0]
        XCTAssertGreaterThan(first, 0)
        XCTAssertTrue(raw.bytes.allSatisfy { $0 == first })
    }

    /// The `VideoPixelBuffer.rawFrame` helper honors the requested channel count.
    func testRawFrameHelperChannelSelection() {
        let red = lgMakeColorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)

        let asRGB = VideoPixelBuffer.rawFrame(from: red, channels: 3)
        XCTAssertEqual(asRGB.channels, 3)
        XCTAssertEqual(asRGB.bytes.count, 2 * 2 * 3)
        XCTAssertEqual(Array(asRGB.bytes.prefix(3)), [255, 0, 0])

        let asRGBA = VideoPixelBuffer.rawFrame(from: red, channels: 4)
        XCTAssertEqual(asRGBA.channels, 4)
        XCTAssertEqual(asRGBA.bytes.count, 2 * 2 * 4)
        XCTAssertEqual(Array(asRGBA.bytes.prefix(4)), [255, 0, 0, 255])

        let asGray = VideoPixelBuffer.rawFrame(from: red, channels: 1)
        XCTAssertEqual(asGray.channels, 1)
        XCTAssertEqual(asGray.bytes.count, 2 * 2)
        // Red channel of a pure-red pixel is 255.
        XCTAssertEqual(asGray.bytes[0], 255)
    }
}
