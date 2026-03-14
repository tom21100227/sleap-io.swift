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

    /// Hint to prefetch frames (best-effort, may be a no-op).
    func prefetch(indices: IndexSet)
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

    public func prefetch(indices: IndexSet) {
        // Default: no-op
    }
}
