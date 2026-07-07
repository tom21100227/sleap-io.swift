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

    /// The canonical backend-type identifier for a virtual on-read crop video
    /// (SLP 2.3 `CropVideoBackend`). A crop video is not inferred from a file
    /// extension — it wraps a source video — so it is identified by this string on
    /// ``backendType`` together with a ``cropRegion`` read from `video_crops` /
    /// `crop` metadata. Registered here alongside ``inferBackendType(_:)`` so the
    /// model layer recognizes it as a first-class backend type.
    public static let cropBackendType = "crop"

    /// Whether `type` names the virtual crop backend (accepts the canonical
    /// ``cropBackendType`` and the upstream `"CropVideo"` spelling).
    public static func isCropBackendType(_ type: String) -> Bool {
        type == cropBackendType || type == "CropVideo"
    }

    /// The axis-aligned crop region `(x1, y1, x2, y2)` in source pixel
    /// coordinates for a virtual crop video, read from `backendMetadata["crop"]`
    /// (or the upstream `["video_crops"]`) as a 4-element integer array; `nil`
    /// when absent. Consumed by the SleapVideo crop backend to map coordinates
    /// and crop frames on read.
    public var cropRegion: (x1: Int, y1: Int, x2: Int, y2: Int)? {
        let raw: Any? = backendMetadata["crop"] ?? backendMetadata["video_crops"]
        guard let arr = Video.intArray(raw), arr.count == 4 else { return nil }
        return (x1: arr[0], y1: arr[1], x2: arr[2], y2: arr[3])
    }

    /// Whether this video is a virtual crop video (its ``backendType`` names the
    /// crop backend and it carries a ``cropRegion``).
    public var isCropVideo: Bool {
        Video.isCropBackendType(backendType) || cropRegion != nil
    }

    /// Infer a backend-type identifier ("media" / "hdf5" / "imageSequence" /
    /// "tiff" / "seq" / "crop") from a file extension.
    ///
    /// The virtual ``cropBackendType`` has no dedicated extension (it wraps a
    /// source video), so it is only produced when `filename` is already the crop
    /// identifier; ordinary paths fall through to their extension-based type.
    static func inferBackendType(_ filename: String) -> String {
        if isCropBackendType(filename) { return cropBackendType }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "m4v", "mkv", "webm", "mpg", "mpeg":
            return "media"
        case "h5", "hdf5", "slp", "pkg":
            return "hdf5"
        case "tif", "tiff":
            // A single (possibly multi-page) TIFF file maps to the multi-page
            // TIFF stack backend. Directories of images are opened explicitly as
            // "imageSequence" instead.
            return "tiff"
        case "seq":
            // Norpix StreamPix .seq container.
            return "seq"
        case "png", "jpg", "jpeg", "bmp", "gif":
            return "imageSequence"
        default:
            return "media"
        }
    }
}
