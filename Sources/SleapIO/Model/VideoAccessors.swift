import Foundation

// E11.1: Video metadata accessors mirroring Python `Video`.
//
// These operate on the in-memory model only. Opening/closing a decode backend
// lives in the SleapVideo module (the SleapIO `Video` type has no backend), so
// `open`/`close`/`isOpen` are intentionally not part of this layer.

extension Video {

    /// Video shape as `(frames, height, width, channels)`, or `nil` if either the
    /// frame count or frame size is unknown. Mirrors `Video.shape`.
    public var shape: (frames: Int, height: Int, width: Int, channels: Int)? {
        guard let n = frameCount, let s = frameSize else { return nil }
        return (n, s.height, s.width, s.channels)
    }

    /// Whether the video is grayscale (single channel), or `nil` if the frame size
    /// is unknown. Setting it updates the channel count of ``frameSize`` (1 for
    /// grayscale, 3 otherwise); a no-op while the frame size is unknown.
    /// Mirrors `Video.grayscale`.
    public var grayscale: Bool? {
        get { frameSize.map { $0.channels == 1 } }
        set {
            guard let want = newValue, let s = frameSize else { return }
            frameSize = (height: s.height, width: s.width, channels: want ? 1 : 3)
        }
    }

    /// Whether the backing file exists on disk at ``filename``. Mirrors `Video.exists`.
    public var exists: Bool {
        var path = filename
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Frames per second, read from `backendMetadata["fps"]` if present.
    public var fps: Double? {
        switch backendMetadata["fps"] {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let f as Float: return Double(f)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Convert a frame index to a time in seconds using ``fps``, or `nil` if unknown.
    public func frameToSeconds(_ frameIndex: Int) -> Double? {
        guard let fps = fps, fps > 0 else { return nil }
        return Double(frameIndex) / fps
    }

    /// Convert a time in seconds to the nearest frame index using ``fps``, or `nil`.
    public func secondsToFrame(_ seconds: Double) -> Int? {
        guard let fps = fps, fps > 0 else { return nil }
        return Int((seconds * fps).rounded())
    }

    /// Create a `Video` inferring the backend type from the file extension.
    /// Mirrors `Video.from_filename`.
    public static func from(filename: String) -> Video {
        Video(filename: filename, backendType: inferBackendType(filename))
    }

    /// Infer a backend-type identifier ("media" / "hdf5" / "imageSequence") from a
    /// file extension.
    static func inferBackendType(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "m4v", "mkv", "webm", "mpg", "mpeg":
            return "media"
        case "h5", "hdf5", "slp", "pkg":
            return "hdf5"
        case "png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif":
            return "imageSequence"
        default:
            return "media"
        }
    }
}
