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

        let time = CMTimeMakeWithSeconds(
            Double(index) / _fps,
            preferredTimescale: duration.timescale
        )

        let (image, _) = try await generator.image(at: time)
        return image
    }

    nonisolated public func prefetch(indices: IndexSet) {
        // AVAssetImageGenerator doesn't support prefetching in this mode
    }
}
