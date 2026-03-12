import CoreGraphics
import Foundation
import SleapIO

/// Storage for video backends, keyed by Video identity.
///
/// Since Video is defined in SleapIO (another module), we can't add stored
/// properties. We use a global dictionary keyed by ObjectIdentifier instead.
private let _backendLock = NSLock()
private var _backends: [ObjectIdentifier: any VideoBackend] = [:]
private var _caches: [ObjectIdentifier: FrameCache] = [:]

extension Video {
    /// The active video backend. Set by `open()` or manually for custom backends.
    public var backend: (any VideoBackend)? {
        get {
            _backendLock.withLock {
                _backends[ObjectIdentifier(self)]
            }
        }
        set {
            _backendLock.withLock {
                _backends[ObjectIdentifier(self)] = newValue
            }
        }
    }

    private var frameCache: FrameCache {
        _backendLock.withLock {
            let key = ObjectIdentifier(self)
            if let existing = _caches[key] { return existing }
            let cache = FrameCache()
            _caches[key] = cache
            return cache
        }
    }

    /// Open the video backend based on `backendType`.
    ///
    /// - "media": AVFoundation backend for video files
    /// - "imageSequence": Image directory backend
    public func open() async throws {
        switch backendType {
        case "media", "MediaVideo":
            let url = URL(fileURLWithPath: filename)
            backend = try await AVFoundationBackend(url: url)
        case "imageSequence", "ImageVideo":
            let url = URL(fileURLWithPath: filename)
            backend = try ImageSequenceBackend(directory: url)
        default:
            throw SleapIOError.videoError("Unknown backend type: \(backendType)")
        }

        // Sync properties from backend
        if let be = backend {
            if frameCount == nil { frameCount = be.frameCount }
            if frameSize == nil { frameSize = be.frameSize }
        }
    }

    /// Close the backend and release resources.
    public func close() {
        _backendLock.withLock {
            let key = ObjectIdentifier(self)
            _backends.removeValue(forKey: key)
            _caches.removeValue(forKey: key)
        }
    }

    /// Extract a single frame by index.
    public func frame(at index: Int) async throws -> CGImage {
        // Check cache first
        if let cached = frameCache.get(index) { return cached }

        guard let be = backend else {
            throw SleapIOError.videoError("Video backend not opened. Call open() first.")
        }

        let image = try await be.frame(at: index)
        frameCache.set(image, for: index)
        return image
    }

    /// Extract a range of frames.
    public func frames(at indices: Range<Int>) async throws -> [CGImage] {
        guard backend != nil else {
            throw SleapIOError.videoError("Video backend not opened. Call open() first.")
        }
        var results: [CGImage] = []
        results.reserveCapacity(indices.count)
        for i in indices {
            results.append(try await frame(at: i))
        }
        return results
    }

    /// Async subscript for frame access.
    public subscript(index: Int) -> CGImage {
        get async throws {
            try await frame(at: index)
        }
    }

    /// Hint to prefetch frames (best-effort).
    public func prefetch(indices: IndexSet) {
        backend?.prefetch(indices: indices)
    }
}
