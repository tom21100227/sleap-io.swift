import CoreGraphics
import Foundation
import SleapIO

/// Storage for video backends, keyed by Video identity.
///
/// Since Video is defined in SleapIO (another module), we can't add stored
/// properties. We use weak-key global tables keyed by Video object identity.
private let _backendLock = NSLock()
private let _backends = NSMapTable<AnyObject, BackendBox>(keyOptions: .weakMemory, valueOptions: .strongMemory)
private let _caches = NSMapTable<AnyObject, CacheBox>(keyOptions: .weakMemory, valueOptions: .strongMemory)
private let _backendOpeners = NSMapTable<AnyObject, OpenerBox>(keyOptions: .weakMemory, valueOptions: .strongMemory)

private final class BackendBox: NSObject {
    let backend: any VideoBackend

    init(_ backend: any VideoBackend) {
        self.backend = backend
    }
}

private final class CacheBox: NSObject {
    let cache: FrameCache

    init(_ cache: FrameCache) {
        self.cache = cache
    }
}

private final class OpenerBox: NSObject {
    let opener: @Sendable () async throws -> any VideoBackend

    init(_ opener: @escaping @Sendable () async throws -> any VideoBackend) {
        self.opener = opener
    }
}

extension Video {
    /// The active video backend. Set by `open()` or manually for custom backends.
    public var backend: (any VideoBackend)? {
        get {
            _backendLock.withLock {
                _backends.object(forKey: self)?.backend
            }
        }
        set {
            _backendLock.withLock {
                if let newValue {
                    _backends.setObject(BackendBox(newValue), forKey: self)
                } else {
                    _backends.removeObject(forKey: self)
                }
            }
        }
    }

    /// Optional custom opener for backends that need module-specific setup.
    public var backendOpener: (@Sendable () async throws -> any VideoBackend)? {
        get {
            _backendLock.withLock {
                _backendOpeners.object(forKey: self)?.opener
            }
        }
        set {
            _backendLock.withLock {
                if let newValue {
                    _backendOpeners.setObject(OpenerBox(newValue), forKey: self)
                } else {
                    _backendOpeners.removeObject(forKey: self)
                }
            }
        }
    }

    private var frameCache: FrameCache {
        _backendLock.withLock {
            if let existing = _caches.object(forKey: self)?.cache { return existing }
            let cache = FrameCache()
            _caches.setObject(CacheBox(cache), forKey: self)
            return cache
        }
    }

    /// Open the video backend based on `backendType`.
    ///
    /// - "media", "MediaVideo": AVFoundation backend for video files
    /// - "imageSequence", "ImageVideo": Image directory backend
    /// - "tiff", "TiffVideo": Multi-page TIFF stack backend
    /// - "seq", "SeqVideo": Norpix StreamPix .seq backend
    /// - "hdf5", "HDF5Video": Embedded HDF5 video (requires loading through Labels.load)
    public func open() async throws {
        if let opener = backendOpener {
            backend = try await opener()
        } else {
            switch backendType {
            case "media", "MediaVideo":
                let url = URL(fileURLWithPath: filename)
                let cache = frameCache
                backend = try await AVFoundationBackend(url: url, frameCache: cache)
            case "imageSequence", "ImageVideo":
                let url = URL(fileURLWithPath: filename)
                backend = try ImageSequenceBackend(directory: url)
            case "tiff", "TiffVideo":
                let url = URL(fileURLWithPath: filename)
                backend = try TiffVideo(url: url)
            case "seq", "SeqVideo":
                let url = URL(fileURLWithPath: filename)
                backend = try SeqVideo(url: url)
            case "hdf5", "HDF5Video":
                throw SleapIOError.videoError(
                    "HDF5 video backend requires loading through Labels.load(from:). " +
                    "The embedded video backend is configured automatically during SLP file loading.")
            default:
                throw SleapIOError.videoError("Unknown backend type: \(backendType)")
            }
        }

        syncMetadataFromBackend()
    }

    /// Close the backend and release resources.
    public func close() {
        _backendLock.withLock {
            _backends.removeObject(forKey: self)
            _caches.removeObject(forKey: self)
        }
    }

    /// Extract a single frame by index.
    public func frame(at index: Int) async throws -> CGImage {
        try await frame(at: index, tolerance: .exact)
    }

    /// Extract a single frame by index with seek tolerance control.
    ///
    /// - `.exact`: uses the frame cache (current default behavior).
    /// - `.adaptive`: bypasses the cache so approximate frames don't pollute exact entries.
    public func frame(at index: Int, tolerance: SeekTolerance) async throws -> CGImage {
        if case .exact = tolerance, let cached = frameCache.get(index) {
            return cached
        }

        guard let be = backend else {
            throw SleapIOError.videoError("Video backend not opened. Call open() first.")
        }

        let image = try await be.frame(at: index, tolerance: tolerance)

        if case .exact = tolerance {
            frameCache.set(image, for: index)
        }

        return image
    }

    /// Extract a range of frames.
    public func frames(at indices: Range<Int>) async throws -> [CGImage] {
        guard let be = backend else {
            throw SleapIOError.videoError("Video backend not opened. Call open() first.")
        }

        var results = Array<CGImage?>(repeating: nil, count: indices.count)
        var uncachedStart: Int?

        func fetchBatch(_ range: Range<Int>) async throws {
            guard !range.isEmpty else { return }
            let images = try await be.frames(at: range)
            for (offset, image) in images.enumerated() {
                let frameIndex = range.lowerBound + offset
                frameCache.set(image, for: frameIndex)
                results[frameIndex - indices.lowerBound] = image
            }
        }

        for index in indices {
            let resultIndex = index - indices.lowerBound
            if let cached = frameCache.get(index) {
                if let start = uncachedStart {
                    try await fetchBatch(start..<index)
                    uncachedStart = nil
                }
                results[resultIndex] = cached
            } else if uncachedStart == nil {
                uncachedStart = index
            }
        }

        if let start = uncachedStart {
            try await fetchBatch(start..<indices.upperBound)
        }

        return results.compactMap { $0 }
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

    private func syncMetadataFromBackend() {
        guard let be = backend else { return }
        if let count = be.frameCount {
            frameCount = count
        }
        if let size = be.frameSize {
            frameSize = size
        }
    }
}
