import XCTest
import AVFoundation
import CoreGraphics
@testable import SleapVideo
import SleapIO

// Each frame is a solid color whose blue channel increases with its index, so the
// decoded blue is a monotonic function of the frame index. We do NOT predict the
// exact decoded value (H.264's YUV/gamma round-trip biases it nonlinearly); instead
// we build a REFERENCE by decoding each frame once, sequentially (no concurrency, so
// known-correct), then assert that a concurrent/prefetched decode of frame t matches
// the reference for t more closely than any other frame. This is robust to codec
// color conversion and needs no magic tolerance.
private func seekMakeFrame(_ i: Int, width: Int, height: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Blue step of 8/index >> codec/gamma jitter, so adjacent frames stay distinct.
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: CGFloat(i * 8) / 255.0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func seekCenterBlue(_ image: CGImage) -> Int {
    var px = [UInt8](repeating: 0, count: 4)
    px.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return Int(px[2]) // RGBA → blue at offset 2
}

private func seekTempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sleap_seek_\(UUID().uuidString).mp4")
}

/// Regression tests for the AVFoundation seek/prefetch concurrency bug: overlapping
/// `frame(at:)` calls used to race on one shared, non-thread-safe generator (throwing
/// or returning the wrong frame), and adaptive prefetch polluted the exact cache.
final class SeekConcurrencyTests: XCTestCase {
    private var url: URL!
    private var reference: [Int] = []   // reference[i] = blue of a sequential exact decode of i
    private let frameCount = 30
    private let width = 640
    private let height = 360

    override func setUp() async throws {
        try await super.setUp()
        url = seekTempURL()
        // Long-GOP so most indices are non-keyframes (exact seeks decode a GOP).
        // High bitrate keeps flat colors crisp so per-index blues stay distinct.
        try await VideoWriter.saveVideo(
            to: url, frames: 0..<frameCount, height: height, width: width,
            fps: 30.0, codec: .h264, bitRate: 20_000_000, keyframeInterval: 10
        ) { [width, height] index in
            seekMakeFrame(index, width: width, height: height)
        }
        // Build the reference sequentially (one decode at a time — no concurrency).
        let refBackend = try await AVFoundationBackend(url: url)
        reference = []
        for i in 0..<frameCount {
            reference.append(seekCenterBlue(try await refBackend.frame(at: i, tolerance: .exact)))
        }
    }

    override func tearDown() async throws {
        if let url { try? FileManager.default.removeItem(at: url) }
        try await super.tearDown()
    }

    /// The frame index whose reference blue is closest to `blue`.
    private func nearestIndex(to blue: Int) -> Int {
        var best = 0, bestDist = Int.max
        for (i, ref) in reference.enumerated() {
            let d = abs(ref - blue)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// PRIMARY: many overlapping exact seeks must each return their own frame and
    /// none may throw. Pre-fix this raced on the shared generator (throw/wrong frame).
    func testOverlappingExactSeeksEachReturnCorrectFrame() async throws {
        let backend = try await AVFoundationBackend(url: url)
        let targets = [15, 3, 22, 8, 27, 19, 11, 25]
        try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for t in targets {
                group.addTask { (t, try await backend.frame(at: t, tolerance: .exact)) }
            }
            for try await (t, img) in group {
                XCTAssertEqual(nearestIndex(to: seekCenterBlue(img)), t,
                               "frame \(t) came back as the wrong/corrupted frame")
            }
        }
    }

    /// Reproduces the open-then-jump overlap: a slow far decode and an immediate jump
    /// run concurrently; both must be correct.
    func testConcurrentFarDecodeAndJumpBothCorrect() async throws {
        let backend = try await AVFoundationBackend(url: url)
        async let far = backend.frame(at: 29, tolerance: .exact)
        async let jump = backend.frame(at: 14, tolerance: .exact)
        let (a, b) = try await (far, jump)
        XCTAssertEqual(nearestIndex(to: seekCenterBlue(b)), 14)
        XCTAssertEqual(nearestIndex(to: seekCenterBlue(a)), 29)
    }

    /// SECONDARY 1: prefetch must feed the exact cache with the EXACT frame, not an
    /// adaptive neighbor. Prefetch a non-keyframe index and confirm the cached image
    /// is that index (not k±1).
    func testPrefetchDoesNotPolluteExactCache() async throws {
        let cache = FrameCache()
        let backend = try await AVFoundationBackend(url: url, frameCache: cache)
        let k = 17 // non-keyframe (keyframes at 0/10/20)
        backend.prefetch(indices: IndexSet(integer: k))

        var cached: CGImage?
        for _ in 0..<200 { // up to ~2s
            if let img = cache.get(k) { cached = img; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let img = try XCTUnwrap(cached, "prefetch never populated the cache for \(k)")
        XCTAssertEqual(nearestIndex(to: seekCenterBlue(img)), k,
                       "prefetch cached a neighbor of \(k), polluting the exact cache")
    }

    /// Regression: a plain single exact decode of several non-keyframe indices is
    /// frame-accurate (guards the per-request-generator change).
    func testSingleExactDecodesAreAccurate() async throws {
        let backend = try await AVFoundationBackend(url: url)
        for k in [4, 13, 21, 26] {
            let img = try await backend.frame(at: k, tolerance: .exact)
            XCTAssertEqual(nearestIndex(to: seekCenterBlue(img)), k, "frame \(k)")
        }
    }
}
