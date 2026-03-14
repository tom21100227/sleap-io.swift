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

    /// Cache for prefetched frames, keyed by frame index.
    /// Bounded to avoid unbounded memory growth on long videos.
    private var prefetchCache: [Int: CGImage] = [:]
    private static let maxPrefetchCacheSize = 64

    /// Handle to the in-flight prefetch task so it can be cancelled on new requests.
    private var prefetchTask: Task<Void, Never>?

    /// Create a backend for a video file.
    public init(url: URL) async throws {
        self.asset = AVURLAsset(url: url)

        // Load video track properties
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw SleapIOError.videoError("No video track found in \(url.lastPathComponent)")
        }

        let size = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        guard fps > 0 else {
            throw SleapIOError.videoError("Invalid frame rate for \(url.lastPathComponent)")
        }

        let displayRect = CGRect(origin: .zero, size: size).applying(preferredTransform)
        let displayWidth = Int(abs(displayRect.width).rounded())
        let displayHeight = Int(abs(displayRect.height).rounded())

        self._fps = Double(fps)
        self.duration = duration
        self._frameCount = Int(CMTimeGetSeconds(duration) * Double(fps))
        self._frameSize = (
            height: displayHeight,
            width: displayWidth,
            channels: 3
        )

        self.generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    nonisolated public var frameCount: Int? { _frameCount }
    nonisolated public var frameSize: (height: Int, width: Int, channels: Int)? { _frameSize }
    nonisolated public var fps: Double? { _fps }

    public func frame(at index: Int) async throws -> CGImage {
        guard index >= 0 && index < _frameCount else {
            throw SleapIOError.videoError("Frame index \(index) out of range [0, \(_frameCount))")
        }

        // Check prefetch cache first
        if let cached = prefetchCache[index] {
            return cached
        }

        let time = CMTimeMakeWithSeconds(
            Double(index) / _fps,
            preferredTimescale: duration.timescale
        )

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

        prefetchTask = Task { [weak self] in
            guard let self else { return }
            let prefetchGenerator = AVAssetImageGenerator(asset: assetRef)
            prefetchGenerator.appliesPreferredTrackTransform = true
            prefetchGenerator.requestedTimeToleranceBefore = .zero
            prefetchGenerator.requestedTimeToleranceAfter = .zero

            for index in indices {
                guard !Task.isCancelled else { return }
                guard index >= 0 && index < frameCount else { continue }

                let alreadyCached = await self.prefetchCache[index] != nil
                if alreadyCached { continue }

                let time = CMTimeMakeWithSeconds(
                    Double(index) / fps,
                    preferredTimescale: timescale
                )

                do {
                    let (image, _) = try await prefetchGenerator.image(at: time)
                    guard !Task.isCancelled else { return }
                    await self._storePrefetchedFrame(image, at: index)
                } catch {
                    continue
                }
            }
        }
    }

    /// Store a prefetched frame in the cache (actor-isolated helper).
    private func _storePrefetchedFrame(_ image: CGImage, at index: Int) {
        // Evict oldest entries when cache exceeds limit
        if prefetchCache.count >= Self.maxPrefetchCacheSize {
            prefetchCache.removeAll(keepingCapacity: true)
        }
        prefetchCache[index] = image
    }
}
