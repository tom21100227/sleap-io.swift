import CoreGraphics
import Foundation
import SleapIO

/// Seek tolerance for frame extraction.
///
/// Controls the trade-off between accuracy and speed when seeking to a frame
/// in temporal video backends (e.g., AVFoundation).
public enum SeekTolerance: Sendable {
    /// Zero tolerance — frame-accurate seeking (annotation, ground truth).
    case exact
    /// Half-frame tolerance — faster approximate seeking (scrubbing, playback).
    case adaptive
}

/// A single decoded frame as a tightly packed, row-major `(height, width, channels)`
/// buffer of 8-bit samples.
///
/// This mirrors the upstream sleap-io `(H, W, C)` ndarray contract returned by
/// `VideoBackend.get_frame`: the `channels` axis is `1` for grayscale videos and
/// `3` for color videos (and `4` when a backend surfaces an alpha channel). The
/// bytes are laid out with no per-row padding, so `bytes.count == height * width *
/// channels` and the sample for pixel `(row, col)` channel `c` lives at
/// `((row * width) + col) * channels + c`.
public struct RawFrame: Sendable, Equatable {
    /// Frame height in pixels.
    public let height: Int
    /// Frame width in pixels.
    public let width: Int
    /// Number of channels per pixel (`1`, `3`, or `4`).
    public let channels: Int
    /// Row-major `(height, width, channels)` samples, tightly packed.
    public let bytes: [UInt8]

    public init(height: Int, width: Int, channels: Int, bytes: [UInt8]) {
        self.height = height
        self.width = width
        self.channels = channels
        self.bytes = bytes
    }

    /// Shape as `(height, width, channels)`, mirroring the upstream ndarray shape.
    public var shape: (height: Int, width: Int, channels: Int) {
        (height, width, channels)
    }
}

/// Protocol for video decoding backends.
///
/// Backends handle frame extraction from different sources (video files,
/// image directories, HDF5 embedded data). The `Video` class delegates
/// all frame access to its backend.
public protocol VideoBackend: Sendable {
    /// Total frame count, or nil if unknown before opening.
    var frameCount: Int? { get }

    /// Frame dimensions, or nil if unknown.
    var frameSize: (height: Int, width: Int, channels: Int)? { get }

    /// Frames per second, or nil for non-temporal sources.
    var fps: Double? { get }

    /// Extract a single frame by index.
    func frame(at index: Int) async throws -> CGImage

    /// Extract a single frame by index with seek tolerance control.
    func frame(at index: Int, tolerance: SeekTolerance) async throws -> CGImage

    /// Extract a range of frames.
    func frames(at indices: Range<Int>) async throws -> [CGImage]

    /// Extract a single frame as a raw row-major `(height, width, channels)` UInt8
    /// buffer, alongside the ``frame(at:)`` `CGImage` path.
    ///
    /// The channel count follows ``frameSize`` (autodetected grayscale collapses to
    /// a single channel), mirroring the upstream `(H, W, C)` ndarray contract.
    func rawFrame(at index: Int) async throws -> RawFrame

    /// Sample the decoded first frame and report whether the video is grayscale.
    ///
    /// Mirrors the upstream `VideoBackend.detect_grayscale`: a frame is considered
    /// grayscale when its first and last color channels are identical for every
    /// pixel. Backends autodetect this on first open to populate
    /// ``frameSize``'s channel count; this hook re-runs the check on demand.
    func detectGrayscale() async throws -> Bool

    /// Hint to prefetch frames (best-effort, may be a no-op).
    func prefetch(indices: IndexSet)

    /// Cancel any in-flight prefetch (best-effort, may be a no-op). Called when a
    /// manual seek supersedes the previous location so the wanted frame isn't
    /// starved of decode bandwidth.
    func cancelPrefetch()
}

// MARK: - Default implementations

extension VideoBackend {
    public func frame(at index: Int, tolerance: SeekTolerance) async throws -> CGImage {
        try await frame(at: index)
    }

    public func frames(at indices: Range<Int>) async throws -> [CGImage] {
        var result = [CGImage]()
        result.reserveCapacity(indices.count)
        for i in indices {
            try await result.append(frame(at: i))
        }
        return result
    }

    /// Default raw-frame path: decode the `CGImage` and extract a tight
    /// `(height, width, channels)` UInt8 buffer, where `channels` follows
    /// ``frameSize`` (falling back to 3 when the size is unknown).
    public func rawFrame(at index: Int) async throws -> RawFrame {
        let image = try await frame(at: index)
        let channels = frameSize?.channels ?? 3
        return VideoPixelBuffer.rawFrame(from: image, channels: channels)
    }

    /// Default grayscale detection: decode the first frame and compare its first
    /// and last color channels for exact equality.
    public func detectGrayscale() async throws -> Bool {
        let image = try await frame(at: 0)
        return VideoPixelBuffer.isGrayscale(image)
    }

    public func prefetch(indices: IndexSet) {
        // Default: no-op
    }

    public func cancelPrefetch() {
        // Default: no-op
    }
}

// MARK: - Pixel-buffer helpers

/// Utilities for turning a decoded `CGImage` into raw sample buffers and for
/// grayscale autodetection. Shared by the concrete ``VideoBackend`` types.
enum VideoPixelBuffer {

    /// Render an image into tightly packed, row-major RGBA8 bytes (no row padding).
    ///
    /// Returns `nil` if a bitmap context could not be created.
    static func rgba8(from image: CGImage) -> (width: Int, height: Int, bytes: [UInt8])? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? (width, height, buffer) : nil
    }

    /// Whether a decoded image is grayscale: the first (R) and last (B) color
    /// channels are identical for every pixel.
    ///
    /// Mirrors the upstream `detect_grayscale` (`test_img[..., 0] ==
    /// test_img[..., -1]`). Returns `false` if the image cannot be sampled.
    static func isGrayscale(_ image: CGImage) -> Bool {
        guard let (width, height, bytes) = rgba8(from: image) else { return false }
        let pixelCount = width * height
        for i in 0..<pixelCount {
            let offset = i * 4
            if bytes[offset] != bytes[offset + 2] { return false }  // R vs B
        }
        return true
    }

    /// Extract a tight `(height, width, channels)` UInt8 buffer from a decoded image.
    ///
    /// - `channels == 1`: takes the red channel, which equals the gray value for a
    ///   grayscale frame (mirrors upstream `img[..., [0]]` collapse).
    /// - `channels == 3`: RGB samples (drops alpha).
    /// - otherwise: full RGBA samples.
    static func rawFrame(from image: CGImage, channels: Int) -> RawFrame {
        guard let (width, height, rgba) = rgba8(from: image) else {
            return RawFrame(
                height: image.height, width: image.width,
                channels: channels, bytes: []
            )
        }
        let pixelCount = width * height

        switch channels {
        case 1:
            var out = [UInt8](repeating: 0, count: pixelCount)
            for i in 0..<pixelCount { out[i] = rgba[i * 4] }
            return RawFrame(height: height, width: width, channels: 1, bytes: out)
        case 4:
            return RawFrame(height: height, width: width, channels: 4, bytes: rgba)
        default:
            var out = [UInt8](repeating: 0, count: pixelCount * 3)
            for i in 0..<pixelCount {
                out[i * 3 + 0] = rgba[i * 4 + 0]
                out[i * 3 + 1] = rgba[i * 4 + 1]
                out[i * 3 + 2] = rgba[i * 4 + 2]
            }
            return RawFrame(height: height, width: width, channels: 3, bytes: out)
        }
    }
}
