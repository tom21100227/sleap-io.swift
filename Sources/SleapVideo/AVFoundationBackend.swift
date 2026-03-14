import AVFoundation
import CoreGraphics
import CoreMedia
import SleapIO

/// Video backend using AVFoundation for media files (mp4, mov, avi).
///
/// Internally serialized as an actor since AVAssetImageGenerator is not thread-safe.
public actor AVFoundationBackend: VideoBackend {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
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
        self.asset = asset
        self.frameCache = nil
        self._fps = info.fps
        self.duration = info.duration
        self._frameCount = info.frameCount
        self._frameSize = info.frameSize
        self.generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    /// Create a backend for a video file with a shared frame cache.
    init(url: URL, frameCache: FrameCache?) async throws {
        let asset = AVURLAsset(url: url)
        let info = try await Self.loadTrackInfo(from: asset)
        self.asset = asset
        self.frameCache = frameCache
        self._fps = info.fps
        self.duration = info.duration
        self._frameCount = info.frameCount
        self._frameSize = info.frameSize
        self.generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
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

        switch tolerance {
        case .exact:
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        case .adaptive:
            let halfFrame = CMTimeMake(value: 1, timescale: Int32(_fps * 2))
            generator.requestedTimeToleranceBefore = halfFrame
            generator.requestedTimeToleranceAfter = halfFrame
        }

        let (image, _) = try await generator.image(at: time)
        return image
    }

    nonisolated public func prefetch(indices: IndexSet) {
        Task { await self._startPrefetch(indices: indices) }
    }

    /// Internal actor-isolated method that cancels any in-flight prefetch and starts a new one.
    private func _startPrefetch(indices: IndexSet) {
        prefetchTask?.cancel()

        let fps = _fps
        let timescale = duration.timescale
        let frameCount = _frameCount
        let assetRef = self.asset
        let cacheRef = self.frameCache

        prefetchTask = Task { [weak self] in
            guard self != nil else { return }
            let prefetchGenerator = AVAssetImageGenerator(asset: assetRef)
            prefetchGenerator.appliesPreferredTrackTransform = true

            // Use adaptive tolerance for prefetch (speed over accuracy)
            let halfFrame = CMTimeMake(value: 1, timescale: Int32(fps * 2))
            prefetchGenerator.requestedTimeToleranceBefore = halfFrame
            prefetchGenerator.requestedTimeToleranceAfter = halfFrame

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
