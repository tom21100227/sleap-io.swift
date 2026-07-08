import AVFoundation
import CoreGraphics
import CoreMedia
import SleapIO

/// Video backend using AVFoundation for media files (mp4, mov, avi).
///
/// Internally serialized as an actor since AVAssetImageGenerator is not thread-safe.
public actor AVFoundationBackend: VideoBackend {
    private let asset: AVURLAsset
    private let _frameCount: Int
    private let _frameSize: (height: Int, width: Int, channels: Int)
    private let _fps: Double
    private let duration: CMTime

    /// Shared frame cache owned by the Video instance.
    /// When non-nil, prefetched frames are stored here instead of a private cache.
    private let frameCache: FrameCache?

    /// Handle to the in-flight prefetch task so it can be cancelled on new requests.
    private var prefetchTask: Task<Void, Never>?

    /// Loaded video track properties (shared between init paths).
    private struct TrackInfo {
        let fps: Double
        let duration: CMTime
        let frameCount: Int
        let frameSize: (height: Int, width: Int, channels: Int)
    }

    private static func loadTrackInfo(from asset: AVURLAsset) async throws -> TrackInfo {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw SleapIOError.videoError("No video track found in \(asset.url.lastPathComponent)")
        }

        let size = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        guard fps > 0 else {
            throw SleapIOError.videoError("Invalid frame rate for \(asset.url.lastPathComponent)")
        }

        let displayRect = CGRect(origin: .zero, size: size).applying(preferredTransform)
        return TrackInfo(
            fps: Double(fps),
            duration: duration,
            frameCount: Int(CMTimeGetSeconds(duration) * Double(fps)),
            frameSize: (
                height: Int(abs(displayRect.height).rounded()),
                width: Int(abs(displayRect.width).rounded()),
                channels: 3
            )
        )
    }

    /// Create a backend for a video file.
    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let info = try await Self.loadTrackInfo(from: asset)
        let generator = Self.makeGenerator(for: asset)
        let channels = await Self.detectChannels(
            generator: generator,
            timescale: info.duration.timescale,
            fallback: info.frameSize.channels
        )
        self.asset = asset
        self.frameCache = nil
        self._fps = info.fps
        self.duration = info.duration
        self._frameCount = info.frameCount
        self._frameSize = (
            height: info.frameSize.height,
            width: info.frameSize.width,
            channels: channels
        )
    }

    /// Create a backend for a video file with a shared frame cache.
    init(url: URL, frameCache: FrameCache?) async throws {
        let asset = AVURLAsset(url: url)
        let info = try await Self.loadTrackInfo(from: asset)
        let generator = Self.makeGenerator(for: asset)
        let channels = await Self.detectChannels(
            generator: generator,
            timescale: info.duration.timescale,
            fallback: info.frameSize.channels
        )
        self.asset = asset
        self.frameCache = frameCache
        self._fps = info.fps
        self.duration = info.duration
        self._frameCount = info.frameCount
        self._frameSize = (
            height: info.frameSize.height,
            width: info.frameSize.width,
            channels: channels
        )
    }

    /// Build an image generator configured for frame-accurate extraction.
    private static func makeGenerator(for asset: AVURLAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    /// Build a per-request image generator with the requested seek tolerance.
    ///
    /// A fresh generator is created per decode so overlapping `frame(at:)` calls
    /// never share (and race on) one `AVAssetImageGenerator` — independent
    /// generators over the same asset decode concurrently safely. This removes the
    /// actor-reentrancy hazard where a suspended decode's tolerance could be
    /// mutated by a second in-flight call.
    private static func makeGenerator(
        for asset: AVURLAsset,
        tolerance: SeekTolerance,
        fps: Double
    ) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        switch tolerance {
        case .exact:
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        case .adaptive:
            let halfFrame = CMTimeMake(value: 1, timescale: Int32(fps * 2))
            generator.requestedTimeToleranceBefore = halfFrame
            generator.requestedTimeToleranceAfter = halfFrame
        }
        return generator
    }

    /// Autodetect the channel count by sampling the decoded first frame: a frame
    /// whose first and last color channels match is grayscale (1 channel),
    /// otherwise color (3 channels). Falls back to `fallback` when the first
    /// frame cannot be decoded.
    private static func detectChannels(
        generator: AVAssetImageGenerator,
        timescale: CMTimeScale,
        fallback: Int
    ) async -> Int {
        let scale = timescale != 0 ? timescale : 600
        let time = CMTimeMakeWithSeconds(0, preferredTimescale: scale)
        guard let (image, _) = try? await generator.image(at: time) else {
            return fallback
        }
        return VideoPixelBuffer.isGrayscale(image) ? 1 : 3
    }

    nonisolated public var frameCount: Int? { _frameCount }
    nonisolated public var frameSize: (height: Int, width: Int, channels: Int)? { _frameSize }
    nonisolated public var fps: Double? { _fps }

    public func frame(at index: Int) async throws -> CGImage {
        try await frame(at: index, tolerance: .exact)
    }

    public func frame(at index: Int, tolerance: SeekTolerance) async throws -> CGImage {
        guard index >= 0 && index < _frameCount else {
            throw SleapIOError.videoError("Frame index \(index) out of range [0, \(_frameCount))")
        }

        let time = CMTimeMakeWithSeconds(
            Double(index) / _fps,
            preferredTimescale: duration.timescale
        )

        // Fresh generator per request — see makeGenerator(for:tolerance:fps:).
        let generator = Self.makeGenerator(for: asset, tolerance: tolerance, fps: _fps)
        return try await withTaskCancellationHandler {
            let (image, _) = try await generator.image(at: time)
            return image
        } onCancel: {
            // Stop a superseded (e.g. slow 4K) decode promptly.
            generator.cancelAllCGImageGeneration()
        }
    }

    nonisolated public func prefetch(indices: IndexSet) {
        Task { await self._startPrefetch(indices: indices) }
    }

    /// Cancel any in-flight prefetch so a fresh manual seek isn't starved of
    /// decode bandwidth (important on large/4K frames).
    nonisolated public func cancelPrefetch() {
        Task { await self._cancelPrefetch() }
    }

    private func _cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// Internal actor-isolated method that cancels any in-flight prefetch and starts a new one.
    private func _startPrefetch(indices: IndexSet) {
        prefetchTask?.cancel()

        let timescale = duration.timescale
        let fps = _fps
        let frameCount = _frameCount
        let assetRef = self.asset
        let cacheRef = self.frameCache

        prefetchTask = Task { [weak self] in
            guard self != nil else { return }
            // Exact tolerance: prefetched frames land in the same FrameCache that
            // `.exact` reads consult, so an adaptive (±½-frame) decode can't cache a
            // neighbor under index k and return the wrong frame on a later exact step.
            let prefetchGenerator = AVAssetImageGenerator(asset: assetRef)
            prefetchGenerator.appliesPreferredTrackTransform = true
            prefetchGenerator.requestedTimeToleranceBefore = .zero
            prefetchGenerator.requestedTimeToleranceAfter = .zero

            for index in indices {
                guard !Task.isCancelled else { return }
                guard index >= 0 && index < frameCount else { continue }

                if cacheRef?.get(index) != nil { continue }

                let time = CMTimeMakeWithSeconds(
                    Double(index) / fps,
                    preferredTimescale: timescale
                )

                do {
                    let (image, _) = try await prefetchGenerator.image(at: time)
                    guard !Task.isCancelled else { return }
                    cacheRef?.set(image, for: index)
                } catch {
                    continue
                }
            }
        }
    }
}
