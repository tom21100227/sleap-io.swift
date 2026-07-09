#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import SleapIO
import SleapVideo

/// Renders pose overlays over a video's frames and encodes to a movie file.
public struct RenderVideo: Sendable {
    public var options: RenderOptions

    public init(options: RenderOptions = .defaults) {
        self.options = options
    }

    /// Low-level: encode `frames` whose final images come from `frameProvider`,
    /// reporting progress in 0...1 after each encoded frame.
    public func render(
        frames: Range<Int>,
        width: Int,
        height: Int,
        to url: URL,
        fps: Double = 30.0,
        codec: VideoWriterCodec = .h264,
        bitRate: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
        frameProvider: @Sendable (Int) async throws -> CGImage
    ) async throws {
        guard width > 0, height > 0 else {
            throw SleapIOError.videoError("RenderVideo requires positive dimensions")
        }

        let writer = try VideoWriter(
            url: url,
            height: height,
            width: width,
            fps: fps,
            codec: codec,
            bitRate: bitRate
        )

        guard !frames.isEmpty else {
            try await writer.finish()
            return
        }

        let total = frames.count
        var count = 0
        for index in frames {
            let image = try await frameProvider(index)
            try await writer.append(image)
            count += 1
            progress?(Double(count) / Double(total))
        }
        try await writer.finish()
    }

    /// High-level: composite `instancesForFrame(i)` over `video.frame(at: i)`
    /// for each frame, encoding the result to `url`.
    public func render(
        video: Video,
        frames: Range<Int>,
        skeleton: Skeleton,
        to url: URL,
        fps: Double? = nil,
        codec: VideoWriterCodec = .h264,
        bitRate: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
        instancesForFrame: @Sendable (Int) -> [Instance]
    ) async throws {
        if video.backend == nil {
            try await video.open()
        }

        guard let size = video.frameSize ?? video.backend?.frameSize else {
            throw SleapIOError.videoError("Cannot render video: unknown frame size")
        }

        let outFPS = fps ?? video.fps ?? 30.0
        try await render(
            frames: frames,
            width: size.width,
            height: size.height,
            to: url,
            fps: outFPS,
            codec: codec,
            bitRate: bitRate,
            progress: progress
        ) { index in
            let base = try await video.frame(at: index)
            return PoseRenderer(options: options).render(
                instances: instancesForFrame(index),
                onto: base,
                skeleton: skeleton
            )
        }
    }
}
#endif
