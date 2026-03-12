import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SleapVideo
import SleapIO

// MARK: - Test Helpers

private func makeTestImage(width: Int = 64, height: Int = 64,
                           red: CGFloat = 1.0, green: CGFloat = 0.0, blue: CGFloat = 0.0) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

@discardableResult
private func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

private func createImageSequenceDirectory(count: Int, width: Int = 64, height: Int = 64) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sleap_video_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    for i in 0..<count {
        let fraction = CGFloat(i) / CGFloat(max(count - 1, 1))
        guard let image = makeTestImage(width: width, height: height, red: fraction, green: 0, blue: 1 - fraction) else {
            throw NSError(domain: "TestHelper", code: 1)
        }
        writePNG(image, to: tempDir.appendingPathComponent(String(format: "frame_%04d.png", i)))
    }
    return tempDir
}

private func cleanupDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

#if canImport(AVFoundation)
import AVFoundation

private func createTestVideo(frameCount: Int = 10, width: Int = 64, height: Int = 64, fps: Double = 30.0) async throws -> URL {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sleap_test_video_\(UUID().uuidString).mp4")
    try? FileManager.default.removeItem(at: outputURL)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    writerInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: writerInput,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )
    writer.add(writerInput)
    guard writer.startWriting() else {
        throw writer.error ?? NSError(domain: "TestHelper", code: 3)
    }
    writer.startSession(atSourceTime: .zero)

    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    for i in 0..<frameCount {
        while !writerInput.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else { throw NSError(domain: "TestHelper", code: 4) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let gray = UInt8(truncatingIfNeeded: (i * 25) % 256)
            for row in 0..<height {
                for col in 0..<width {
                    let off = row * bytesPerRow + col * 4
                    ptr[off] = gray; ptr[off+1] = gray; ptr[off+2] = gray; ptr[off+3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(i)))
    }
    writerInput.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "TestHelper", code: 5) }
    return outputURL
}
#endif

// MARK: - Mock VideoBackend

final class MockVideoBackend: VideoBackend, @unchecked Sendable {
    let _frameCount: Int?
    let _frameSize: (height: Int, width: Int, channels: Int)?
    let _fps: Double?
    var frameAccessLog: [Int] = []

    init(frameCount: Int? = 10, frameSize: (height: Int, width: Int, channels: Int)? = (64, 64, 3), fps: Double? = 30.0) {
        self._frameCount = frameCount; self._frameSize = frameSize; self._fps = fps
    }

    var frameCount: Int? { _frameCount }
    var frameSize: (height: Int, width: Int, channels: Int)? { _frameSize }
    var fps: Double? { _fps }

    func frame(at index: Int) async throws -> CGImage {
        frameAccessLog.append(index)
        guard let img = makeTestImage(width: _frameSize?.width ?? 64, height: _frameSize?.height ?? 64) else {
            throw NSError(domain: "Mock", code: 1)
        }
        return img
    }
}

// MARK: - VideoBackend Protocol Tests

final class VideoBackendProtocolTests: XCTestCase {
    func testMockFrameCount() { XCTAssertEqual(MockVideoBackend(frameCount: 42).frameCount, 42) }
    func testMockNilFrameCount() { XCTAssertNil(MockVideoBackend(frameCount: nil).frameCount) }
    func testMockFrameSize() {
        let s = MockVideoBackend(frameSize: (1080, 1920, 3)).frameSize
        XCTAssertEqual(s?.height, 1080); XCTAssertEqual(s?.width, 1920)
    }
    func testMockFPS() { XCTAssertEqual(MockVideoBackend(fps: 29.97).fps!, 29.97, accuracy: 0.001) }
    func testMockNilFPS() { XCTAssertNil(MockVideoBackend(fps: nil).fps) }
    func testMockFrameReturnsImage() async throws {
        let img = try await MockVideoBackend().frame(at: 0)
        XCTAssertEqual(img.width, 64)
    }
    func testDefaultFramesBatch() async throws {
        let imgs = try await MockVideoBackend().frames(at: 0..<3)
        XCTAssertEqual(imgs.count, 3)
    }
    func testEmptyRange() async throws {
        let empty = try await MockVideoBackend().frames(at: 0..<0)
        XCTAssertTrue(empty.isEmpty)
    }
}

// MARK: - AVFoundation Backend Tests

#if canImport(AVFoundation)
final class AVFoundationBackendTests: XCTestCase {
    private var testVideoURL: URL?

    override func setUp() async throws {
        testVideoURL = try await createTestVideo(frameCount: 10, width: 64, height: 64, fps: 30.0)
    }
    override func tearDown() { if let u = testVideoURL { try? FileManager.default.removeItem(at: u) } }

    func testInitValid() async throws {
        let be = try await AVFoundationBackend(url: testVideoURL!)
        XCTAssertNotNil(be)
    }
    func testFrameCount() async throws {
        let be = try await AVFoundationBackend(url: testVideoURL!)
        XCTAssertNotNil(be.frameCount)
        XCTAssertGreaterThan(be.frameCount!, 0)
    }
    func testFrameSize() async throws {
        let be = try await AVFoundationBackend(url: testVideoURL!)
        XCTAssertEqual(be.frameSize?.width, 64)
        XCTAssertEqual(be.frameSize?.height, 64)
    }
    func testFPS() async throws {
        let be = try await AVFoundationBackend(url: testVideoURL!)
        XCTAssertEqual(be.fps!, 30.0, accuracy: 1.0)
    }
    func testFrameExtraction() async throws {
        let be = try await AVFoundationBackend(url: testVideoURL!)
        let img = try await be.frame(at: 0)
        XCTAssertEqual(img.width, 64)
    }
    func testOutOfRangeThrows() async throws {
        let be = try await AVFoundationBackend(url: testVideoURL!)
        do { _ = try await be.frame(at: 99999); XCTFail("Expected error") } catch {}
    }
    func testNegativeIndexThrows() async throws {
        let be = try await AVFoundationBackend(url: testVideoURL!)
        do { _ = try await be.frame(at: -1); XCTFail("Expected error") } catch {}
    }
    func testInvalidURLThrows() async {
        do { _ = try await AVFoundationBackend(url: URL(fileURLWithPath: "/nonexistent.mp4")); XCTFail("Expected error") } catch {}
    }
}
#endif

// MARK: - ImageSequence Backend Tests

final class ImageSequenceBackendTests: XCTestCase {
    private var imageDir: URL?

    override func setUp() async throws {
        imageDir = try createImageSequenceDirectory(count: 8, width: 80, height: 60)
    }
    override func tearDown() { if let d = imageDir { cleanupDirectory(d) } }

    func testInit() throws {
        let be = try ImageSequenceBackend(directory: imageDir!)
        XCTAssertNotNil(be)
    }
    func testFrameCount() throws {
        let be = try ImageSequenceBackend(directory: imageDir!)
        XCTAssertEqual(be.frameCount, 8)
    }
    func testFrameSize() throws {
        let be = try ImageSequenceBackend(directory: imageDir!)
        XCTAssertEqual(be.frameSize?.width, 80)
        XCTAssertEqual(be.frameSize?.height, 60)
    }
    func testFPSNil() throws {
        XCTAssertNil(try ImageSequenceBackend(directory: imageDir!).fps)
    }
    func testFrameAt() async throws {
        let be = try ImageSequenceBackend(directory: imageDir!)
        let img = try await be.frame(at: 0)
        XCTAssertEqual(img.width, 80)
    }
    func testOutOfRange() async throws {
        let be = try ImageSequenceBackend(directory: imageDir!)
        do { _ = try await be.frame(at: 100); XCTFail("Expected error") } catch {}
    }
    func testNegativeIndex() async throws {
        let be = try ImageSequenceBackend(directory: imageDir!)
        do { _ = try await be.frame(at: -1); XCTFail("Expected error") } catch {}
    }
    func testEmptyDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sleap_empty_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanupDirectory(dir) }
        let be = try ImageSequenceBackend(directory: dir)
        XCTAssertEqual(be.frameCount, 0)
    }
    func testNonExistentDirThrows() {
        do { _ = try ImageSequenceBackend(directory: URL(fileURLWithPath: "/nonexistent")); XCTFail("Expected error") } catch {}
    }
}

// MARK: - FrameCache Tests

final class FrameCacheTests: XCTestCase {
    func testStoreAndRetrieve() {
        let cache = FrameCache()
        guard let img = makeTestImage(width: 32, height: 32) else { XCTFail(""); return }
        cache.set(img, for: 42)
        XCTAssertNotNil(cache.get(42))
        XCTAssertEqual(cache.get(42)?.width, 32)
    }
    func testMissReturnsNil() {
        XCTAssertNil(FrameCache().get(99))
    }
    func testOverwrite() {
        let cache = FrameCache()
        cache.set(makeTestImage(width: 32, height: 32)!, for: 10)
        cache.set(makeTestImage(width: 64, height: 64)!, for: 10)
        XCTAssertEqual(cache.get(10)?.width, 64)
    }
    func testRemoveAll() {
        let cache = FrameCache()
        cache.set(makeTestImage()!, for: 0)
        cache.set(makeTestImage()!, for: 1)
        cache.removeAll()
        XCTAssertNil(cache.get(0))
        XCTAssertNil(cache.get(1))
    }
}

// MARK: - Video Extension Tests

final class VideoExtensionTests: XCTestCase {
    func testOpenImageSequence() async throws {
        let dir = try createImageSequenceDirectory(count: 5)
        defer { cleanupDirectory(dir) }
        let video = Video(filename: dir.path, backendType: "imageSequence")
        try await video.open()
        XCTAssertEqual(video.frameCount, 5)
        video.close()
    }

    func testFrameForImageSequence() async throws {
        let dir = try createImageSequenceDirectory(count: 3, width: 40, height: 30)
        defer { cleanupDirectory(dir) }
        let video = Video(filename: dir.path, backendType: "imageSequence")
        try await video.open()
        let img = try await video.frame(at: 1)
        XCTAssertEqual(img.width, 40)
        video.close()
    }

    func testCloseAndReopen() async throws {
        let dir = try createImageSequenceDirectory(count: 3)
        defer { cleanupDirectory(dir) }
        let video = Video(filename: dir.path, backendType: "imageSequence")
        try await video.open()
        video.close()
        try await video.open()
        XCTAssertEqual(video.frameCount, 3)
        video.close()
    }

    func testAsyncSubscript() async throws {
        let dir = try createImageSequenceDirectory(count: 5, width: 50, height: 50)
        defer { cleanupDirectory(dir) }
        let video = Video(filename: dir.path, backendType: "imageSequence")
        try await video.open()
        let img = try await video[2]
        XCTAssertEqual(img.width, 50)
        video.close()
    }

    func testFrameWithoutOpenThrows() async {
        let video = Video(filename: "/some/path.mp4", backendType: "media")
        do { _ = try await video.frame(at: 0); XCTFail("Expected error") } catch {}
    }

    func testFrameSizePopulatedAfterOpen() async throws {
        let dir = try createImageSequenceDirectory(count: 2, width: 100, height: 75)
        defer { cleanupDirectory(dir) }
        let video = Video(filename: dir.path, backendType: "imageSequence")
        try await video.open()
        XCTAssertEqual(video.frameSize?.width, 100)
        XCTAssertEqual(video.frameSize?.height, 75)
        video.close()
    }

    func testIdentityPreserved() async throws {
        let dir = try createImageSequenceDirectory(count: 2)
        defer { cleanupDirectory(dir) }
        let video = Video(filename: dir.path, backendType: "imageSequence")
        let same = video
        XCTAssertTrue(video === same)
        try await video.open()
        XCTAssertTrue(video === same)
        video.close()
    }

    #if canImport(AVFoundation)
    func testOpenMediaBackend() async throws {
        let url = try await createTestVideo(frameCount: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = Video(filename: url.path, backendType: "media")
        try await video.open()
        XCTAssertNotNil(video.frameCount)
        XCTAssertGreaterThan(video.frameCount!, 0)
        video.close()
    }
    #endif
}
