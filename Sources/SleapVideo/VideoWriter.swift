#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import SleapIO

/// Output codec for ``VideoWriter``.
public enum VideoWriterCodec: Sendable {
    /// H.264 / AVC.
    case h264
    /// HEVC / H.265.
    case hevc

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// Encodes a sequence of `CGImage` frames to a movie file via `AVAssetWriter`.
///
/// Frames are appended sequentially and encoded with the configured codec,
/// bitrate, and keyframe interval. Call ``finish()`` to flush and close the
/// file.
///
/// Mirrors the upstream sleap-io `VideoWriter` / `save_video`. `AVFoundation`
/// controls quality via average bitrate (and an optional per-frame quality
/// factor) rather than the x264 CRF knob, so ``init(url:height:width:fps:codec:bitRate:quality:keyframeInterval:fileType:)``
/// exposes `bitRate`/`quality` in place of `crf`.
public actor VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Double
    private let width: Int
    private let height: Int
    private var nextFrameIndex: Int = 0
    private var started = false
    private var finished = false

    /// Create a writer.
    ///
    /// - Parameters:
    ///   - url: Destination file (overwritten if it exists).
    ///   - height: Frame height in pixels.
    ///   - width: Frame width in pixels.
    ///   - fps: Frame rate.
    ///   - codec: Output codec (default H.264).
    ///   - bitRate: Average bitrate in bits/sec. `nil` lets the encoder choose.
    ///   - quality: Per-frame quality factor in `0...1` (CRF analog). `nil` to omit.
    ///   - keyframeInterval: Maximum frames between keyframes. `nil` for default.
    ///   - fileType: Container type (default `.mp4`).
    public init(
        url: URL,
        height: Int,
        width: Int,
        fps: Double = 30.0,
        codec: VideoWriterCodec = .h264,
        bitRate: Int? = nil,
        quality: Double? = nil,
        keyframeInterval: Int? = nil,
        fileType: AVFileType = .mp4
    ) throws {
        guard width > 0, height > 0 else {
            throw SleapIOError.videoError("VideoWriter requires positive dimensions")
        }
        guard fps > 0 else {
            throw SleapIOError.videoError("VideoWriter requires a positive frame rate")
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        var compression: [String: Any] = [:]
        if let bitRate { compression[AVVideoAverageBitRateKey] = bitRate }
        if let quality { compression[AVVideoQualityKey] = quality }
        if let keyframeInterval {
            compression[AVVideoMaxKeyFrameIntervalKey] = keyframeInterval
        }
        compression[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded())

        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if !compression.isEmpty {
            settings[AVVideoCompressionPropertiesKey] = compression
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw SleapIOError.videoError("AVAssetWriter rejected the video input")
        }
        writer.add(input)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.fps = fps
        self.width = width
        self.height = height
    }

    /// Append the next frame in sequence.
    public func append(_ image: CGImage) async throws {
        let index = nextFrameIndex
        nextFrameIndex += 1
        try await append(image, at: index)
    }

    /// Append a frame at an explicit index (presentation time `index / fps`).
    public func append(_ image: CGImage, at index: Int) async throws {
        guard !finished else {
            throw SleapIOError.videoError("VideoWriter already finished")
        }
        if !started {
            guard writer.startWriting() else {
                throw writer.error
                    ?? SleapIOError.videoError("AVAssetWriter failed to start")
            }
            writer.startSession(atSourceTime: .zero)
            started = true
        }

        // Wait until the input can accept more data.
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard let buffer = VideoWriter.makePixelBuffer(from: image, width: width, height: height) else {
            throw SleapIOError.videoError("Failed to create pixel buffer for frame \(index)")
        }
        let time = CMTimeMakeWithSeconds(Double(index) / fps, preferredTimescale: 600)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error
                ?? SleapIOError.videoError("Failed to append frame \(index)")
        }
        nextFrameIndex = max(nextFrameIndex, index + 1)
    }

    /// Flush and finalize the file.
    public func finish() async throws {
        guard !finished else { return }
        finished = true
        if !started {
            // Nothing was written; still produce a valid (empty) container.
            guard writer.startWriting() else {
                throw writer.error
                    ?? SleapIOError.videoError("AVAssetWriter failed to start")
            }
            writer.startSession(atSourceTime: .zero)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error
                ?? SleapIOError.videoError("AVAssetWriter finished with status \(writer.status.rawValue)")
        }
    }

    // MARK: - Convenience

    /// Encode a range of frames supplied by a provider closure.
    ///
    /// - Parameters:
    ///   - url: Destination file.
    ///   - frames: Frame indices to encode (in order).
    ///   - height: Frame height.
    ///   - width: Frame width.
    ///   - fps: Frame rate.
    ///   - codec: Output codec.
    ///   - bitRate: Optional average bitrate.
    ///   - keyframeInterval: Optional keyframe interval.
    ///   - provider: Async closure returning the `CGImage` for a frame index.
    public static func saveVideo(
        to url: URL,
        frames: Range<Int>,
        height: Int,
        width: Int,
        fps: Double = 30.0,
        codec: VideoWriterCodec = .h264,
        bitRate: Int? = nil,
        keyframeInterval: Int? = nil,
        provider: (Int) async throws -> CGImage
    ) async throws {
        let writer = try VideoWriter(
            url: url,
            height: height,
            width: width,
            fps: fps,
            codec: codec,
            bitRate: bitRate,
            keyframeInterval: keyframeInterval
        )
        for index in frames {
            let image = try await provider(index)
            try await writer.append(image)
        }
        try await writer.finish()
    }

    // MARK: - Pixel buffer construction

    /// Render a `CGImage` into a 32-BGRA `CVPixelBuffer`.
    static func makePixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // 32BGRA == little-endian ARGB with premultiplied first alpha.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

// MARK: - Video convenience

extension Video {
    /// Encode a range of this video's frames to a new movie file.
    ///
    /// The video must already be opened (``open()``). Frames are pulled through
    /// the active backend and re-encoded with ``VideoWriter``.
    ///
    /// - Parameters:
    ///   - range: Frame indices to export.
    ///   - url: Destination file.
    ///   - fps: Output frame rate. Defaults to the source ``fps`` or 30.
    ///   - codec: Output codec.
    ///   - bitRate: Optional average bitrate.
    ///   - keyframeInterval: Optional keyframe interval.
    public func saveFrames(
        _ range: Range<Int>,
        to url: URL,
        fps: Double? = nil,
        codec: VideoWriterCodec = .h264,
        bitRate: Int? = nil,
        keyframeInterval: Int? = nil
    ) async throws {
        guard let size = frameSize ?? backend?.frameSize else {
            throw SleapIOError.videoError("Cannot save frames: unknown frame size")
        }
        let outFPS = fps ?? self.fps ?? 30.0
        try await VideoWriter.saveVideo(
            to: url,
            frames: range,
            height: size.height,
            width: size.width,
            fps: outFPS,
            codec: codec,
            bitRate: bitRate,
            keyframeInterval: keyframeInterval
        ) { index in
            try await self.frame(at: index)
        }
    }
}
#endif
