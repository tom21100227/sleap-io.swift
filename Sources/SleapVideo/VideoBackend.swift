import CoreGraphics
import Foundation
import SleapIO

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

    /// Extract a range of frames.
    func frames(at indices: Range<Int>) async throws -> [CGImage]

    /// Hint to prefetch frames (best-effort, may be a no-op).
    func prefetch(indices: IndexSet)
}

// MARK: - Default implementations

extension VideoBackend {
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
