import CoreGraphics
import Foundation
import SleapIO

// MARK: - Virtual on-read crop video backend (SLP 2.3 / #70)
//
// Mirrors the upstream `CropVideoBackend` / `video_crops` feature: a virtual
// axis-aligned crop that wraps a *source* ``VideoBackend`` and crops each frame
// on read, without ever materializing a cropped copy on disk. Coordinates map
// between the source and crop frames via ``CropRegion/toCrop(_:)`` /
// ``CropRegion/toSource(_:)`` (the inverse of upstream `crop_points`), and frame
// pixels are cropped with out-of-bounds fill (mirroring `crop_frame`).

/// An axis-aligned crop region, `(x1, y1, x2, y2)` in *source* pixel
/// coordinates. `x1`/`y1` are the top-left corner (inclusive) and `x2`/`y2` the
/// bottom-right (exclusive), so the cropped frame is ``width`` x ``height``.
public struct CropRegion: Sendable, Equatable {
    public let x1: Int
    public let y1: Int
    public let x2: Int
    public let y2: Int

    public init(x1: Int, y1: Int, x2: Int, y2: Int) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// Convenience initializer from a ``Video/cropRegion`` tuple.
    public init(_ region: (x1: Int, y1: Int, x2: Int, y2: Int)) {
        self.init(x1: region.x1, y1: region.y1, x2: region.x2, y2: region.y2)
    }

    /// Crop width in pixels (`x2 - x1`).
    public var width: Int { x2 - x1 }
    /// Crop height in pixels (`y2 - y1`).
    public var height: Int { y2 - y1 }

    /// Map a point from *source* coordinates into *crop* coordinates.
    ///
    /// Mirrors upstream `crop_points`: subtract the crop origin. `NaN`
    /// coordinates (missing points) are preserved.
    public func toCrop(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - CGFloat(x1), y: point.y - CGFloat(y1))
    }

    /// Map a point from *crop* coordinates back into *source* coordinates (the
    /// inverse of ``toCrop(_:)``). `NaN` coordinates are preserved.
    public func toSource(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + CGFloat(x1), y: point.y + CGFloat(y1))
    }

    /// Crop a raw `(H, W, C)` frame to this region, filling any out-of-bounds
    /// area with `fill`. Mirrors upstream `crop_frame`.
    ///
    /// Returns a ``RawFrame`` of size ``height`` x ``width`` with the same channel
    /// count as `frame`. If `frame`'s byte buffer is not tightly packed to its
    /// declared shape, an all-`fill` frame of the crop size is returned.
    public func apply(to frame: RawFrame, fill: UInt8 = 0) -> RawFrame {
        let channels = frame.channels
        let outWidth = max(0, width)
        let outHeight = max(0, height)
        var out = [UInt8](repeating: fill, count: outWidth * outHeight * channels)

        let expected = frame.width * frame.height * channels
        guard outWidth > 0, outHeight > 0, frame.bytes.count == expected, expected > 0 else {
            return RawFrame(
                height: outHeight, width: outWidth, channels: channels, bytes: out)
        }

        // Valid overlap between the crop rect and the source frame.
        let srcX1 = max(0, x1)
        let srcY1 = max(0, y1)
        let srcX2 = min(frame.width, x2)
        let srcY2 = min(frame.height, y2)
        guard srcX2 > srcX1, srcY2 > srcY1 else {
            return RawFrame(
                height: outHeight, width: outWidth, channels: channels, bytes: out)
        }

        out.withUnsafeMutableBufferPointer { dst in
            frame.bytes.withUnsafeBufferPointer { src in
                for sy in srcY1..<srcY2 {
                    let dy = sy - y1
                    let srcRow = sy * frame.width * channels
                    let dstRow = dy * outWidth * channels
                    for sx in srcX1..<srcX2 {
                        let dx = sx - x1
                        let srcOff = srcRow + sx * channels
                        let dstOff = dstRow + dx * channels
                        for ch in 0..<channels {
                            dst[dstOff + ch] = src[srcOff + ch]
                        }
                    }
                }
            }
        }

        return RawFrame(
            height: outHeight, width: outWidth, channels: channels, bytes: out)
    }
}

/// A ``VideoBackend`` that virtually crops a source backend's frames on read.
///
/// Frame reads are delegated to the wrapped ``source`` backend and cropped to
/// ``crop`` (out-of-bounds regions filled with ``fill``). The reported
/// ``frameSize`` reflects the crop dimensions while ``frameCount`` and ``fps``
/// pass through from the source. Landmark coordinates can be mapped with
/// ``toCrop(_:)`` / ``toSource(_:)``.
public struct CropVideoBackend: VideoBackend {
    /// The wrapped source backend supplying full-frame pixels.
    public let source: any VideoBackend
    /// The crop region in source pixel coordinates.
    public let crop: CropRegion
    /// Fill value for out-of-bounds regions (per channel).
    public let fill: UInt8

    public init(source: any VideoBackend, crop: CropRegion, fill: UInt8 = 0) {
        self.source = source
        self.crop = crop
        self.fill = fill
    }

    public var frameCount: Int? { source.frameCount }

    public var frameSize: (height: Int, width: Int, channels: Int)? {
        (height: crop.height, width: crop.width, channels: source.frameSize?.channels ?? 3)
    }

    public var fps: Double? { source.fps }

    public func frame(at index: Int) async throws -> CGImage {
        let cropped = try await rawFrame(at: index)
        return try CropVideoBackend.makeImage(from: cropped)
    }

    public func rawFrame(at index: Int) async throws -> RawFrame {
        let raw = try await source.rawFrame(at: index)
        return crop.apply(to: raw, fill: fill)
    }

    public func detectGrayscale() async throws -> Bool {
        try await source.detectGrayscale()
    }

    public func prefetch(indices: IndexSet) {
        source.prefetch(indices: indices)
    }

    /// Map a point from source coordinates into crop coordinates.
    public func toCrop(_ point: CGPoint) -> CGPoint { crop.toCrop(point) }

    /// Map a point from crop coordinates back into source coordinates.
    public func toSource(_ point: CGPoint) -> CGPoint { crop.toSource(point) }

    /// Build a `CGImage` from a raw `(H, W, C)` frame by expanding to RGBA8.
    static func makeImage(from raw: RawFrame) throws -> CGImage {
        let width = raw.width
        let height = raw.height
        let channels = raw.channels
        guard width > 0, height > 0, raw.bytes.count == width * height * channels else {
            throw SleapIOError.videoError(
                "Cannot build image from empty or malformed cropped frame.")
        }

        let pixelCount = width * height
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            let dst = i * 4
            switch channels {
            case 1:
                let v = raw.bytes[i]
                rgba[dst] = v
                rgba[dst + 1] = v
                rgba[dst + 2] = v
                rgba[dst + 3] = 255
            case 4:
                let src = i * 4
                rgba[dst] = raw.bytes[src]
                rgba[dst + 1] = raw.bytes[src + 1]
                rgba[dst + 2] = raw.bytes[src + 2]
                rgba[dst + 3] = raw.bytes[src + 3]
            default:  // 3 channels (or other): take the first three as RGB.
                let src = i * channels
                rgba[dst] = raw.bytes[src]
                rgba[dst + 1] = raw.bytes[src + 1]
                rgba[dst + 2] = raw.bytes[src + 2]
                rgba[dst + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            throw SleapIOError.videoError("Failed to create image data provider.")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw SleapIOError.videoError("Failed to construct cropped CGImage.")
        }
        return image
    }
}

// MARK: - Video crop-backend construction

extension Video {
    /// Build a ``CropVideoBackend`` for this crop video by wrapping `source`,
    /// reading the crop region from this video's `video_crops` / `crop` metadata
    /// (see ``cropRegion``).
    ///
    /// - Parameters:
    ///   - source: The backend of the uncropped source video to wrap.
    ///   - fill: Out-of-bounds fill value (default `0`).
    /// - Returns: A configured crop backend, or `nil` if this video carries no
    ///   ``cropRegion``.
    public func makeCropBackend(
        source: any VideoBackend, fill: UInt8 = 0
    ) -> CropVideoBackend? {
        guard let region = cropRegion else { return nil }
        return CropVideoBackend(source: source, crop: CropRegion(region), fill: fill)
    }
}
